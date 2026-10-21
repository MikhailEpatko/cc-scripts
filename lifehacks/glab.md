Сначала пробовал установить через Homebrew, но на macOS 26 с Intel у brew нет готовых сборок, и он начал компилировать 
с нуля сам Go, а за ним и glab. 

Поставил glab командой: `go install` 

Вышло быстрее, но есть два нюанса:

- посмотреть версию: `go version -m ~/go/bin/glab`

- обновить glab: `go install gitlab.com/gitlab-org/cli/cmd/glab@latest`
  
Чтобы glab мог ходить в GitLab, нужно авторизоваться. Команда: `glab auth login --hostname gitlab.example.com`

Для API токену нужен scope `read_api`.