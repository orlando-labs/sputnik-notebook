# Remote core в интерфейсе ноутбука

## Подключение

Сборка приложения: `make notebook-macos`. Рядом с GUI и внутри `.app` находится
native `sputnik-notebook-remote`, собранный из Sputnik с `--require-full-native`.
HTTP, подготовка immutable upload, CAS и receipts используют этот клиент;
SwiftUI управляет выбором сервера, привязкой документа и отображением.

Откройте `.sputnikbook`, нажмите **Servers… → Save and Connect**. Для тестового
сервера поля уже заполнены:

| Поле | Значение |
|---|---|
| Connection | SSH tunnel |
| SSH host | `lab.orlando-labs.com` |
| SSH port | `22176` |
| Core port | `18765` |
| State directory | `/home/slowpilot/sputnik-remote-core/state` |

Нужен настроенный SSH key и известный host key: используется системный OpenSSH
с `BatchMode=yes`. Приложение читает token через SSH и создаёт loopback tunnel
на свободном локальном порту. При reconnect открывается новый tunnel.
Другой вариант — HTTPS endpoint и access token; HTTP разрешён для loopback.

Профили находятся в `~/Library/Application Support/Sputnik Notebook/Remote`.
Каталоги закрыты правами 0700, credentials и журналы — 0600; token не хранится
в notebook и не передаётся аргументом процесса. Изменение адреса профиля создаёт
новый профиль, сохраняя доступ к прежнему серверу и его работам.

## Запуск и реконнект

Выбор сервера сохраняется в `.sputnik/remote.json` внутри notebook. Каждая пара
notebook/server получает свой ProjectId. Можно переключиться на **This Mac**,
не останавливая принятые серверные Run; привязки остальных серверов сохраняются.

Run Selected и Run All отправляют на сервер текущие буферы всех листов и модулей,
описания досок и bundled resources. Неизменённый `project.json` передаётся
дословно; изменённый документ сериализуется общим C++ loader с сохранением
неизвестных полей и точных чисел. Изменения синхронизируются после паузы в вводе;
**Sync** и Run также публикуют полный snapshot.

Перед отправкой сохраняются immutable request и CommandId. После подтверждения
временные payload files удаляются, checkpoint исходников и receipts остаются.
При потерянном ответе клиент сначала запрашивает receipt и при необходимости
повторяет ту же команду. Notebook metadata не разрешают выполнение кода сами
по себе: resend Run требует точного ticket в приватном журнале приложения.

Disconnect и закрытие приложения останавливают наблюдение и tunnel. Они не
посылают Stop, Restart или Delete. Повторное открытие привязанного notebook
восстанавливает registry, runtime epoch, принятый Run, progress и presentations.
Reattach не повторяет ячейки. Можно также выбрать **Projects… → Download…**:
копия сохраняет модули, листы, доски, ресурсы и привязку к существующему проекту;
откройте её для восстановления результатов и работающих runtime.

Последние синхронизированные несохранённые буферы восстанавливаются, когда
сохранённые файлы на диске не изменились отдельно. Новые правки редактора не
заменяются завершившимся старым Run. Результаты от прежнего source показываются
как устаревшие. Закрытие с явным Discard не должно восстанавливать отвергнутый
локальный checkpoint; отличия от оставшейся серверной копии требуют выбора.

При конфликте ревизий автоматическая публикация прекращается. Можно скачать
серверную копию или явно выбрать **Publish local version…**. Даже после этого
новый параллельный edit вызывает CAS conflict, а прежняя серверная ревизия
остаётся в истории. Непрочитанная/неизвестная remote binding блокирует удалённый
Run; сетевой сбой не переключает выполнение на локальную машину.

## Представления и управление

### Worker Settings и runtime grants

Кнопка **Worker Settings…** рядом с **Servers…** открывает политику выбранного
листа на выбранном сервере или **This Mac**. Для локального module tab можно
настроить его отдельный worker. Гранты вводятся по одному на строку в формате
`capability=target`; без `=target` capability разрешена для всех targets:

```text
process.spawn=/usr/bin/nvidia-smi
fs.read=/data
net.connect=api.example.com:443
```

**Clear grants** очищает явную политику. **Apply and Restart Worker** проверяет
весь список и сбрасывает worker;
код не исполняется, drafts и последние результаты сохраняются. Новые гранты
действуют со следующего Run. Занятый worker нужно сначала остановить. Local
Action и Periodic Work используют гранты controller sheet; изменение политики
также завершает эти invocation runtimes и приостанавливает periodic services.
Разрешения native trust (`ffi.call`, `ffi.load`, `fs.read`) остаются отдельными.

Локальная политика хранится в приватном файле приложения
`Remote/local-worker-grants.json`, отдельно для пути notebook и tab ID.
Серверная политика хранится в `worker_settings` базы remote core, отдельно для
ProjectId/sheet ID, и переживает reconnect и restart агента. Исходники,
`project.json` и скачанный notebook не выдают grants сами по себе.

Remote core объявляет `worker_grants` в health. Нужны обновлённые core и worker;
старый сервер показывает сообщение об обновлении в окне настроек. API:
`GET/PUT /v1/projects/<project>/worker-settings/<sheet>`. PUT содержит
`command_id`, `base_version`, `runtime_epoch`, `grants: ["cap[=target]", ...]`.
Core проверяет capability names тем же parser, что worker, до изменения
состояния; неверная политика, занятый runtime, устаревшая версия или epoch
оставляют worker без изменений. Receipt делает повтор PUT идемпотентным:
повтор не сбрасывает созданный впоследствии runtime. CLI-команды
`worker_settings` и `configure_worker --request-file ...` используют тот же API.

Bootstrap `registry` содержит короткие metadata без истории stdout и JSON
результатов. Execution document, live и terminal binary presentations
скачиваются отдельно. Формат presentation и его проверка общие с local worker:
таблицы, вывод, locals, progress, figures, charts и images проходят существующий
bridge. Source, selection, formatting и новые drafts принадлежат редактору.
Terminal results восстанавливаются для всех листов; live запрашивается для
видимого листа. Перекрывающиеся refresh сериализованы на клиенте.

Несколько листов могут работать одновременно. Stop/Force Stop адресуются Run и
epoch выбранного листа; Stop не требует предварительного скачивания результата.
Force Stop и смена module environment требуют явного Restart Worker. Модули
синхронизируются вместе с unsaved source; автоматического replay при restart нет.

GUI host в remote mode не исполняет ячейки, inputs или Watch локально. Текущий
remote core поддерживает code/text sheets, bundled modules, revisions,
reattach и Stop/Force Stop. Dependency/native bundles, typed inputs, Apply,
idle Watch pump и Periodic Work пока не включены. Локальные параметры ячеек
`notebook.cell_input(...)` и редактирование pre/post-компонентов поддерживаются:
**Components…** сохраняет конфигурацию в ревизии, Apply атомарно передаёт
параметры серверу. Watch обновляется в уже запущенном worker, Manual остаётся
устаревшей до Run; неинициализированный лист не запускается. Принятые значения
сохраняются на сервере отдельно от defaults и восстанавливаются при reconnect. GPU heap/checkpoints после
гибели агента или узла не восстанавливаются автоматически.

## Проверки

`make test-notebook-remote` проверяет 22 сценария реального core на macOS и
Linux. `make test-notebook-remote-ui` запускает SwiftUI/model с отдельными
agent/gateway и настоящим worker: выбор сервера, source/бинарные ресурсы, live,
закрытие/открытие клиента, тот же Run/epoch, более новые drafts, серверную копию,
Force Stop/restart, параллельные листы, потерянный acknowledgement и отказ
исполнять поддельную pending-команду из notebook metadata. Также проверяются
Discard, конфликт с другим writer и отсутствие локального fallback при неизвестном
профиле сервера.

Для реального SSH smoke в `build/notebook_macos_remote_tests` есть `--ssh-live`:
передайте `--root /tmp/NEW_DIR`, `--core /absolute/path/to/sputnik-notebook-remote`
и `--worker /absolute/path/to/sputnik-notebook-worker`. Проверка создаёт отдельный
серверный проект, закрывает первый SSH tunnel и восстанавливает тот же Run/epoch
из нового model. В `--root` сохраняются `ssh-result.json` и `remote-ui.png`.

Проверка 2026-10-15 на `lab.orlando-labs.com:22176` использовала именно клиент
из собранного `.app`. После закрытия первого клиента новый model открыл новый
SSH tunnel и восстановил Run `1abe5e228406768ecf7cb5e986cf222f`
с прежним epoch `d086d8ba6297c98560fe6586be22d882` и результатом `42`.
Локальные артефакты проверки: `build/remote-ssh-smoke-result.json` и
`build/remote-ssh-smoke.png`. Это проверка удалённого Sputnik execution;
GPU/native dependency bundles в ней не используются.

## Cell components и параметры

Обновлённый core объявляет capability `cell_inputs`. Endpoint
`GET/PUT /v1/projects/<project>/cell-inputs` возвращает `{version, values}`.
`values` — map `"<cell-id>:<input-name>" → scalar JSON string`; числа Int64
не проходят через Double. PUT принимает `command_id`, `revision`, `base_version`,
`cell_id` и map `values` с локальными именами. Core проверяет весь batch общим
C++ валидатором worker до публикации. Устаревшие revision/version, неизвестное
имя, неверный тип/диапазон или занятый worker оставляют состояние без изменений.
Равный batch не создаёт Run. Для существующего worker ответ содержит `run_id`;
Inputs использует обычные live presentations, Stop и историю. Для нового листа
сохраняются только значения.

Каждый Run сохраняет точный execution document отдельно от исходной ревизии.
Смена параметров не переписывает defaults и не создаёт ревизию исходников.
При изменении определения совместимые принятые значения сохраняются,
несовместимые заменяются новым default, удалённые ключи исчезают.
Повтор PUT с тем же CommandId возвращает receipt; потеря acknowledgement не
повторяет Watch. Восстановление незавершённого Apply требует точного ticket в
приватном журнале приложения, как и восстановление Run. Notebook sidecar сам
по себе не разрешает вычисления.
