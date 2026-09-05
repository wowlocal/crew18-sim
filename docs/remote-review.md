# Сервер ревью на Mac

Tapflow запускает relay и iOS agent вместе как пользовательский LaunchAgent
`io.podlodka.tapflow`. Используем один выделенный симулятор и последовательное
ревью сборок.

## Текущий Mac mini

- Dashboard: [localhost:4000](http://localhost:4000).
- Стартовая игра: [сборка №1](http://localhost:4000/app-center/build?id=1).
- Администратор: `admin@podlodka.local`.
- Пароль только на Mac: `.tapflow-host/admin-credentials.json`, права `600`.
- Устройство: **Podlodka Review**, iPhone 17, iOS 26.5.
- Node 26.7.0 выбран только для этого сервиса.

Путь к Node и UDID симулятора находятся в `.tapflow-host/local.env`, вне Git.
Данные администратора и сборки сохранены локально; клонирование репозитория
не копирует их на другой Mac.

## Установка на другом Mac

Нужны Apple Silicon Mac, Xcode с установленным iOS Simulator runtime и Node.js
22 или новее. Запустите Xcode один раз и завершите первоначальную настройку.
Убедитесь, что `xcode-select -p` указывает на нужный Xcode.

```sh
git clone git@github.com:wowlocal/crew18-sim.git
cd crew18-sim/.tapflow-host
npm ci --ignore-scripts
npm rebuild @tapflowio/ios-agent better-sqlite3 --ignore-scripts=false
cd ..
```

Устанавливайте зависимости тем же Node, с которым будет работать сервис:
`better-sqlite3` содержит нативный модуль. В `package.json` разрешены install-скрипты
закреплённых версий iOS agent и better-sqlite3.

Создайте отдельный iPhone в Xcode → **Window → Devices and Simulators → Simulators**,
назовите его `Podlodka Review` и узнайте UDID:

```sh
xcrun simctl list devices available
```

Передайте UDID установщику вместо `DEVICE_UDID`:

```sh
./scripts/install-review-host.sh DEVICE_UDID
```

Скрипт проверяет устройство, сохраняет абсолютный путь к текущему Node, создаёт
LaunchAgent и запускает Tapflow. Для выбора другого Node задайте `NODE_BINARY`.
Повторная установка переводит сервис `io.podlodka.tapflow` в текущую папку проекта.
При переносе остановите сервис и скопируйте его данные заранее.

На новом сервере откройте [первоначальную настройку](http://localhost:4000/setup)
и создайте администратора. Проверить окружение можно так:

```sh
cd .tapflow-host
node node_modules/tapflow/bin/tapflow.js doctor ios
```

## Подготовка и ревью сборок

Участник запускает `./scripts/build-review.sh` в своём форке и передаёт
`build/review/PodlodkaDive.app.zip`. Вывод компилятора сохраняется в
`build/review/build.log`.

Ревьюер загружает архив через **Upload build**. В подписи укажите имя участника,
ссылку на форк и коммит: у разных работ могут совпадать версия и bundle ID.
Начальный проект имеет bundle ID `io.podlodka.dive`, версию 1.0 и build 1.

Выберите **Start QA**, этот Mac и **Podlodka Review**. Если открылся домашний экран,
нажмите **Launch app**. После ревью завершите сессию перед запуском следующей
сборки. Порядок приёма работ и назначения ревьюеров организуется отдельно.

## Управление

```sh
./scripts/review-host.sh status
./scripts/review-host.sh stop
./scripts/review-host.sh start
./scripts/review-host.sh restart
./scripts/review-host.sh logs
```

Сервис запускается после входа пользователя в macOS, перезапускается при сбое
и использует `caffeinate -i`, чтобы Mac не уходил в сон от бездействия.
После перезагрузки требуется войти в пользовательскую сессию.

## Данные и сеть

- База, загруженные сборки и JWT secret: `.tapflow-host/.tapflow/data/`.
- Логи: `.tapflow-host/logs/`.
- LaunchAgent: `~/Library/LaunchAgents/io.podlodka.tapflow.plist`.
- Эти данные, `local.env` и файл пароля исключены из Git. Перед резервным
  копированием базы остановите сервис или используйте резервное копирование
  средствами SQLite.

Tapflow 0.20.1 слушает все интерфейсы без отдельного параметра адреса.
`prepare-local-binding.mjs` меняет установленный listener на `127.0.0.1`.
При неожиданном изменении upstream-кода запуск завершается с ошибкой.
Патч выполняется при каждом старте.

Внешний доступ, домен, TLS и аккаунты ревьюеров отложены. При их настройке
потребуется отдельно проверить авторизацию и доверие к reverse proxy.
Сейчас в пуле только выделенный симулятор. Захват системного аудио отключён,
дополнительный сетевой фильтр Tapflow не установлен.

## Проверено

На текущем Mac исходный Xcode-проект собран и загружен в Tapflow. В браузере
проверены запуск игры, удержание для тяги, перезапуск и пауза; поток был около
25–31 fps. Внешняя задержка и несколько одновременных ревью-сессий ещё не проверены.

Документация Tapflow: [установка](https://www.tapflow.dev/guide/getting-started),
[self-hosting](https://www.tapflow.dev/guide/self-hosting).
