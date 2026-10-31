# StageStrip

Боковые панели с миниатюрами недавних окон на каждом экране. Окна остаются на рабочем столе; системный «Постановщик» нужно выключить вручную.

Сборка: `./build.sh`. Приложение будет в `~/Applications/StageStrip.app`. Для первого запуска откройте его из Finder и выдайте «Универсальный доступ» и «Запись экрана» в настройках macOS. Сторона панели задаётся отдельно для каждого экрана через значок в строке меню. Значок можно скрыть пунктом меню или перетаскиванием с Cmd; скрытие переживает перезапуск, а вернёт значок открытие уже запущенного StageStrip.

Автозапуск: `sed "s|__HOME__|$HOME|" local.stagestrip.plist > ~/Library/LaunchAgents/local.stagestrip.plist && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.stagestrip.plist`. Отключение: `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/local.stagestrip.plist; rm ~/Library/LaunchAgents/local.stagestrip.plist`.

Сброс разрешений: `tccutil reset Accessibility local.stagestrip` и `tccutil reset ScreenCapture local.stagestrip`. После сброса перезапустите приложение.
