#!/usr/bin/env bash

set -euo pipefail

PROXY="http://127.0.0.1:10808"
BASE_URL="https://downloads.claude.ai/claude-code-releases"
DOWNLOAD_DIR="$HOME/.claude/downloads"
VERSIONS_DIR="$HOME/.local/share/claude/versions"
LAUNCHER="$HOME/.local/bin/claude"
SETTINGS="$HOME/.claude/settings.json"
# Сколько попыток подряд без единого скачанного байта считать «загрузка безнадёжна»
MAX_STALLED_ATTEMPTS=20

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "нужен curl"
command -v jq   >/dev/null || die "нужен jq"

# --- платформа ---------------------------------------------------------------
case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux)  os=linux ;;
    *) die "неподдерживаемая ОС: $(uname -s)" ;;
esac
case "$(uname -m)" in
    x86_64|amd64)  arch=x64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) die "неподдерживаемая архитектура: $(uname -m)" ;;
esac
# x64-шелл под Rosetta на Apple Silicon — качаем нативный arm64
if [ "$os" = darwin ] && [ "$arch" = x64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = 1 ]; then
    arch=arm64
fi
platform="$os-$arch"
if [ "$os" = linux ] && { [ -f /lib/libc.musl-x86_64.so.1 ] || [ -f /lib/libc.musl-aarch64.so.1 ]; }; then
    platform="$platform-musl"
fi

sha256() {
    if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
file_size() { stat -f %z "$1" 2>/dev/null || stat -c %s "$1"; }
version_of() { "$1" --version 2>/dev/null | awk '{print $1}' || true; }

# --- прокси ------------------------------------------------------------------
# Если VPN не поднят, не падаем, а идём напрямую
CURL_PROXY=(-x "$PROXY")
if ! curl -fsS -x "$PROXY" --connect-timeout 5 --max-time 15 -o /dev/null "$BASE_URL/stable" 2>/dev/null; then
    warn "прокси $PROXY недоступен — пробую напрямую"
    CURL_PROXY=(--noproxy '*')
fi

fetch() {
    curl -fsSL "${CURL_PROXY[@]}" --connect-timeout 15 --max-time 60 \
         --retry 5 --retry-delay 2 --retry-all-errors "$1"
}

# --- 1. проверка обновления --------------------------------------------------
channel=$(jq -r '.autoUpdatesChannel // "stable"' "$SETTINGS" 2>/dev/null || true)
[[ "$channel" =~ ^(stable|latest)$ ]] || channel=stable

current=""
[ -x "$LAUNCHER" ] && current=$(version_of "$LAUNCHER")
[ -z "$current" ] && command -v claude >/dev/null && current=$(version_of claude)

log "Проверяю обновления в канале '$channel' ..."
version=$(fetch "$BASE_URL/$channel" | tr -d '[:space:]') || die "не удалось получить номер версии с $BASE_URL"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || die "сервер вернул что-то не похожее на версию: '$version'"

log "Установлена: ${current:-нет}; в канале: $version"
if [ -n "$current" ] && \
   [ "$(printf '%s\n%s\n' "$current" "$version" | sort -V | tail -n1)" = "$current" ]; then
    log "Обновление не требуется."
    exit 0
fi

# --- 2. загрузка с докачкой --------------------------------------------------
manifest=$(fetch "$BASE_URL/$version/manifest.json") || die "не удалось скачать манифест $version"
checksum=$(jq -r --arg p "$platform" '.platforms[$p].checksum // empty' <<<"$manifest")
size=$(jq -r --arg p "$platform" '.platforms[$p].size // empty' <<<"$manifest")
[[ "$checksum" =~ ^[a-f0-9]{64}$ ]] || die "в манифесте нет платформы $platform"
[[ "$size" =~ ^[0-9]+$ ]] || die "в манифесте нет размера для $platform"

mkdir -p "$DOWNLOAD_DIR"
binary="$DOWNLOAD_DIR/claude-$version-$platform"
part="$binary.part"
url="$BASE_URL/$version/$platform/claude"

download() {
    # Битый остаток больше ожидаемого размера — начинаем заново
    if [ -f "$part" ] && [ "$(file_size "$part")" -gt "$size" ]; then rm -f "$part"; fi

    log "Скачиваю $version для $platform ($((size / 1024 / 1024)) МБ) ..."
    local have prev=-1 stalled=0 attempt=0
    while :; do
        have=0; [ -f "$part" ] && have=$(file_size "$part")
        [ "$have" -ge "$size" ] && return 0

        # Пока данные прибывают — пробуем бесконечно; сдаёмся только после серии пустых попыток
        if [ "$have" -le "$prev" ]; then
            stalled=$((stalled + 1))
            [ "$stalled" -lt "$MAX_STALLED_ATTEMPTS" ] || \
                die "загрузка не продвигается $MAX_STALLED_ATTEMPTS попыток подряд; скачано $((have / 1024 / 1024)) МБ — при следующем запуске продолжится с этого места"
            sleep $((stalled < 10 ? stalled * 3 : 30))
        else
            stalled=0
        fi
        prev=$have
        attempt=$((attempt + 1))
        [ "$attempt" -gt 1 ] && log "Продолжаю с $((have / 1024 / 1024)) из $((size / 1024 / 1024)) МБ (попытка $attempt)"

        # --speed-limit/--speed-time рвут зависшее соединение, -C - продолжает с места обрыва
        curl -fL "${CURL_PROXY[@]}" -C - --connect-timeout 15 \
             --speed-limit 1024 --speed-time 30 \
             --progress-bar -o "$part" "$url" || warn "соединение прервано (код $?)"
    done
}

if [ -f "$binary" ] && [ "$(sha256 "$binary")" = "$checksum" ]; then
    log "Уже скачано ранее: $binary"
else
    rm -f "$binary"
    # Если контрольная сумма не сошлась — качаем ещё раз с нуля (один повтор)
    for try in 1 2; do
        download
        log "Проверяю SHA-256 ..."
        if [ "$(sha256 "$part")" = "$checksum" ]; then
            mv "$part" "$binary"
            break
        fi
        rm -f "$part"
        [ "$try" -eq 1 ] && warn "контрольная сумма не совпала — скачиваю заново" || die "контрольная сумма снова не совпала"
    done
fi
chmod +x "$binary"

# --- 3. проверка и установка -------------------------------------------------
[ "$(version_of "$binary")" = "$version" ] || die "скачанный бинарник не запускается или сообщает не ту версию"

mkdir -p "$VERSIONS_DIR"
# Неудачный 'claude update' оставляет пустой/битый файл версии — заменяем проверенным
tmp="$VERSIONS_DIR/.$version.tmp.$$"
cp "$binary" "$tmp"
chmod +x "$tmp"
mv -f "$tmp" "$VERSIONS_DIR/$version"

log "Устанавливаю ..."
proxy_env=()
[ "${CURL_PROXY[0]}" = "-x" ] && proxy_env=(HTTPS_PROXY="$PROXY" HTTP_PROXY="$PROXY" https_proxy="$PROXY" http_proxy="$PROXY")
env ${proxy_env[@]+"${proxy_env[@]}"} "$VERSIONS_DIR/$version" install "$channel" </dev/null \
    || warn "штатная установка завершилась с ошибкой — переключаю ссылку вручную"

# Гарантируем, что лаунчер указывает на новую версию
if [ "$(version_of "$LAUNCHER")" != "$version" ]; then
    mkdir -p "$(dirname "$LAUNCHER")"
    ln -sfn "$VERSIONS_DIR/$version" "$LAUNCHER"
fi

installed=$(version_of "$LAUNCHER")
[ "$installed" = "$version" ] || die "после установки $LAUNCHER сообщает версию '$installed', ожидалась $version"

rm -f "$binary"
log "Готово: ${current:-—} -> $installed. Перезапусти открытые сессии Claude, чтобы перейти на новую версию."
