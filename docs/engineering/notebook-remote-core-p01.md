# Remote core P01: серверный владелец выполнения

Первый этап реализации, обновление 2026-10-15. Продолжает [архитектуру remote worker](notebook-remote-worker-architecture.md).

Это single-user preview серверного ядра и CLI с [подключённым macOS GUI](notebook-remote-ui.md): выбор сервера, remote Run, live presentation и reattach к существующему Run/epoch. GPU/native packages, inputs, module Run, Apply, idle Watch и серверные периодические расписания остаются следующими этапами; неподдерживаемые пути не переключаются на локальное исполнение.

## Процессы

- `core.s` — постоянный Execution Agent на Sputnik. Хранит ревизии проекта, receipts, RunId/runtime epoch, состояния и события в SQLite WAL с synchronous FULL. Владеет worker IPC и жизненным циклом runtime.
- `server.s` — заменяемый HTTP gateway на Sputnik, слушающий loopback. Передаёт запросы агенту через приватный Unix socket. Его перезапуск и потеря HTTP-клиента не уничтожают runtime.
- `client.s` — native CLI на Sputnik. Перед отправкой изменения сохраняет локальный receipt с CommandId, маршрутом и хешем запроса.
- `host.s` / `host.cpp` — тонкий native binding к существующим `Process` и `PresentationAssembler`. Метаданные, синхронизация, протокол HTTP и orchestration реализованы в Sputnik. Agent непосредственно владеет worker; отдельный runner не нужен.

Все три режима входят в `build/sputnik-notebook-remote`. Сборка требует `--require-full-native`: bytecode fallback и VM bridge не допускаются. SQLite подключается через sibling package `sqlite3`; C++17 нужен существующему notebook worker и его IPC binding. Python используется только тестовым harness.

Конструкторы используют параметры `@field`, включая `def init(@status, @message)` у `APIError`. Дополнения языка и stdlib: `super(...)`, `fs.atomic_write_text/bytes`, `fs.lock`, `fs.entries`, `net.unix.listen/connect`, `Json.parse(duplicate_keys: :reject)`. Контракты описаны в sibling `sputnik-lang/docs/engineering/{super-dispatch,remote-io-api}.md`.

Agent root имеет права 0700. Gateway требует bearer token из `ROOT/token`; token не выводится в журнал. Публичный TCP listener отсутствует: gateway слушает `127.0.0.1`. Запросы IPC обрабатываются в отдельных параметрических frame; accept loop не передаёт между обработчиками изменяемую переменную сокета.

## Что работает

Загрузка полного проекта сохраняет исходный `project.json`, bundled modules, ресурсы и board descriptions. Общий language-owned loader проверяет staged snapshot до публикации. Сохранение head, receipt и revision event — одна транзакция. Старые ревизии остаются доступны через API.

Run/Run All явно указывают ProjectRevision, sheet и cell. Agent сначала сохраняет запуск и только потом отправляет работу worker. Один runtime на лист, одна активная invocation на runtime. Child tasks участвуют в обычном drain; ошибки необработанных descendants не превращаются в succeeded из-за успешного root value.

При сохранении новой ревизии во время Run текущий запуск продолжает старую. Следующий Run синхронизирует исходники листа в idle worker. Если изменились module/resource bundle или auto-import configuration, preview требует явного Restart Runtime: Apply новой EnvironmentRevision пока не реализован.

При удалении листа или ячейки-владельца отдельного Run в той же транзакции сохраняется stopping. После commit агент отправляет Stop. Удалённые sheet/cell IDs сохраняются в tombstones и не переиспользуются. Удаление проекта запрещает новые работы, принудительно завершает его runtime и сохраняет историю; deleted публикуется после завершения процессов. Обычные доски не владеют отдельными runtime. После Restart старое воплощение сохраняется в отдельном реестре владельцев до подтверждённого завершения процесса; deleted ждёт также этих runtime, даже если лист уже получил новое воплощение. Критерий завершения проверяется по runtime_records внутри SQL-транзакции, чтобы не опередить фиксацию terminal-состояния.

JSON summary содержит результаты, текстовый вывод, progress, environment error, cancellation и unobserved task failures. Полная переносимая presentation, включая остальные поля, сохраняется как бинарный артефакт. Latest live summary заменяется, а не добавляется в бесконечный event log.

Повтор CommandId с тем же содержимым запроса, независимо от порядка JSON-ключей, возвращает прежний receipt; изменённое содержимое с тем же ID даёт conflict. Receipt проверяется раньше head precondition. После потери ответа Run можно получить receipt без повторного запуска. History/event cursor позволяет заново получить список работ и продолжить чтение событий; polling используется до отдельного streaming transport.

Отказ агента закрывает управляющие сокеты worker; его control loop подтверждает потерю владельца и завершает процесс. При следующем старте незавершённые записи становятся interrupted; код не повторяется. Перезапуск gateway сохраняет и выполняющуюся работу, и живой idle runtime.

## Сборка и тестирование

Из `sputnik-notebook`:

```sh
make -j4 remote-core
make test-notebook-remote
# Linux со strace: реальный отказ directory fsync в изолированном агенте
make test-notebook-remote-fsync
```

Для указанного тестового сервера доступен GCC 13:

```sh
make -j8 remote-core CXX=/opt/rh/gcc-toolset-13/root/usr/bin/g++ \
  BUILD_DIR=build-remote SPUTNIK_BUILD_DIR=../sputnik-lang/build-remote \
  OPENSSL_PREFIX=/home/slowpilot/sputnik-remote-core/deps/openssl
```

Интеграционные тесты запускают отдельные agent/gateway, используют реальный native worker и проверяют: auth, восстановление snapshots модулей/досок/ресурсов, output artifact, потерянный ответ Run, повтор CommandId, рестарт gateway во время вычисления, изменения source во время Run, CAS conflict, Stop/Force Stop, stale epoch, удаление owner/project, отказ агента без replay и ошибки дочерних задач.

Проверка 2026-10-15: native-реализация прошла 20 интеграционных сценариев на macOS и Linux-узле с GCC 13, включая native CLI, восемь параллельных IPC-клиентов, создание нового state root с предками, глубокое дерево ресурсов после аварийного рестарта агента и отказ публикации manifest до commit metadata. Новые IO API, включая `fs.sync`, проверены в VM и full-native на обеих платформах; super также проверен на обеих платформах. Существующие parser, JSON, IO, registry, FFI и worker regressions прошли на macOS. Проверка restart с заблокированной metadata database подтверждает, что heap сохраняется до долговечной записи intent; повтор старого restart не останавливает новое воплощение runtime.

Отдельный Linux-тест `tests/notebook_remote_fsync_fault_test.py` запускает изолированный native-агент под strace и внедряет EIO в directory fsync вложенного snapshot. Проверяется, что прежний head остаётся доступным, receipt отсутствует и после перезапуска агента тот же CommandId завершает публикацию. Путь отказавшего системного вызова проверяется по trace, чтобы отличить эту ошибку от более ранней atomic write.

На тестовом узле glibc 2.28 и системный OpenSSL 1.1.1. OpenSSL 3.5.9 подготовлен в отдельном prefix из [официального релиза](https://openssl-library.org/source/) с проверкой SHA256. На glibc до 2.29 `system.command(...).with(cwd: ...)` явно сообщает ProcessSpawnError; операции без cwd продолжают работать. Системные библиотеки узла не заменяются.

## Запуск сервисов

Первое развёртывание на `lab.orlando-labs.com:22176` использует отдельный каталог `/home/slowpilot/sputnik-remote-core`, без изменения других приложений сервера. Исходники размещены в `src/sputnik-lang` и `src/sputnik-notebook`, состояние — в `state`.

2026-10-15 Python preview заменён на native-сервис Sputnik. Перед заменой подтверждено отсутствие активных Run и сохранён SQL backup metadata в `backups/metadata-before-native-*.sql`; token и история сохранены. Agent и gateway запущены отдельными detached процессами. PID-файлы: `agent.pid` и `gateway.pid`; журналы: `agent.log` и `gateway.log`, рядом со `state`. Прежний проверочный проект `remote_smoke` сохранён; новый `remote_smoke_native` доступен через CLI. Sputnik Run с ожиданием 12 секунд продолжил выполнение после закрытия SSH-клиента и перезапуска gateway, завершился с результатом `42` и сохранил idle runtime с тем же runtime epoch. Проверочный RunId: `42066821b500896b1fb824b0b6a223cc`; доказательство сохранено на сервере в `smoke-native-result.json`. Доступ локального CLI через временный SSH-туннель также проверен. Финальный native build использует отдельные `build-remote` directories и GCC 13 с `-O1` через `/home/slowpilot/sputnik-remote-core/cxx`. Production entrypoints на Python и отдельный runner удалены.

В тот же день развёрнуто обновление с `fs.sync`. Проверка отсутствия активных Run и остановка агента выполнены под writer lock SQLite, чтобы новый Run не мог зафиксироваться между этими шагами. Metadata и прежний бинарник сохранены в `backups/metadata-before-fsync-*.sql` и `backups/remote-core-before-fsync-*`. Замена агента завершает прежние idle heap; соответствующие runtime records получают interrupted без replay, документы и история сохраняются. Установка нового бинарника использует временный файл и rename, позволяя заменить исполняемый файл работающего Linux-сервиса. На обновлённом сервисе native CLI загрузил `remote_fsync_smoke_4b3d550d`: исходный JSON с доской, модуль и глубокие бинарные ресурсы сверены дословно, receipt получен, Run `6a6bd9090eaafe2821f510d19385e845` вернул `42`. Результат проверки — `fsync-smoke-result.json` рядом со state.

Также развёрнут GUI protocol: короткий registry, отдельный execution document и binary live presentation. Перед заменой сохранены `backups/metadata-before-gui-1792058423.sql` и `backups/remote-core-before-gui-1792058423`; активных Run не было. Реальный macOS-клиент из `.app` подтвердил закрытие SSH tunnel и reattach к тому же Run/epoch; подробности и инструкции — в [описании GUI](notebook-remote-ui.md).

2026-10-16 развёрнуты явные настройки grants для worker (`worker_grants` в health).
Linux-сборка и 22 интеграционных сценария проверены отдельно в
`releases/worker-grants-20261016`; затем core и worker атомарно заменены в
обычном `src/sputnik-notebook/build-remote`. Проверка отсутствия активных Run,
backup metadata и остановка агента выполнены под writer lock SQLite. Два idle
runtime сброшены без replay. База и прежние бинарники находятся в
`backups/worker-grants-20261016T080442Z`, изменённые исходники — в его `sources`.
Основной серверный checkout синхронизирован с проверенной сборкой.

На рабочем gateway отдельный проверочный проект подтвердил отказ `nvidia-smi`
без гранта, успешный запуск с `process.spawn=/usr/bin/nvidia-smi` и отказ после
отзыва разрешения. Проверочный проект удалён через API с сохранением истории.
Существующие проекты, их head revisions и история Run сохранены; целостность
SQLite подтверждена. Отчёт — `releases/worker-grants-20261016/deploy-result.json`.

Из серверного checkout:

```sh
build-remote/sputnik-notebook-remote --mode agent \
  --root /home/slowpilot/sputnik-remote-core/state \
  --worker /home/slowpilot/sputnik-remote-core/src/sputnik-notebook/build-remote/sputnik-notebook-worker
```

После старта агента, в другом процессе:

```sh
build-remote/sputnik-notebook-remote --mode gateway \
  --root /home/slowpilot/sputnik-remote-core/state --port 18765
```

При обслуживании заменяется gateway. Агент нельзя незаметно перезапускать при живых runtime. `nohup` позволяет отделить процессы от SSH-сессии; управление запуском после перезагрузки узла в этот этап не входит.

Каждый runtime получает собственный рабочий каталог `state/runtimes/{runtime_id}/work`. Относительные операции пользовательского кода выполняются там. Исходники проекта и immutable snapshots хранятся отдельно; пути и публикация произвольных выходных файлов через API будут добавлены с resource/artifact bridge.

## Работа с локального клиента

Открыть туннель:

```sh
ssh -p 22176 -N -L 18765:127.0.0.1:18765 lab.orlando-labs.com
```

Скопировать token в защищённый локальный файл и использовать его через `--token-file`; не передавать token в аргументе команды. Пример получения файла:

```sh
scp -P 22176 lab.orlando-labs.com:/home/slowpilot/sputnik-remote-core/state/token /tmp/sputnik-remote-token
chmod 600 /tmp/sputnik-remote-token
```

CLI из `sputnik-notebook`:

```sh
build/sputnik-notebook-remote --mode cli --token-file /tmp/sputnik-remote-token --command health
build/sputnik-notebook-remote --mode cli --token-file /tmp/sputnik-remote-token --command upload --project experiment --directory /path/to/Experiment.sputnikbook
build/sputnik-notebook-remote --mode cli --token-file /tmp/sputnik-remote-token --command run --project experiment --revision REVISION --sheet main --cell 1 --command-id train-001
build/sputnik-notebook-remote --mode cli --token-file /tmp/sputnik-remote-token --command receipt --project experiment --command-id train-001
build/sputnik-notebook-remote --mode cli --token-file /tmp/sputnik-remote-token --command runs --project experiment
build/sputnik-notebook-remote --mode cli --token-file /tmp/sputnik-remote-token --command status --run-id RUN_ID
build/sputnik-notebook-remote --mode cli --token-file /tmp/sputnik-remote-token --command stop --run-id RUN_ID
build/sputnik-notebook-remote --mode cli --token-file /tmp/sputnik-remote-token --command stop --run-id RUN_ID --force
```

Для повторной загрузки нужен `upload ... --base CURRENT_REVISION`. `REVISION` и `RUN_ID` берутся из ответов CLI. Туннель и клиент можно закрыть после подтверждения Run; при повторном подключении `runs`/`status` показывают ту же работу.

## HTTP API v1

| Запрос | Назначение |
|---|---|
| GET `/v1/health` | Версия протокола и capabilities |
| GET `/v1/projects` | Проекты, включая tombstones |
| PUT `/v1/projects/{id}` | `command_id`, `base_revision`, `document` как исходная JSON-строка, `files` как полный map path→base64 |
| GET `/v1/projects/{id}` | Head и актуальный документ |
| GET `/v1/projects/{id}/revisions/{revision}` | Исторический документ и полный file bundle |
| GET `/v1/projects/{id}/revisions/{revision}/document` | Только execution document, без file bundle |
| GET `/v1/projects/{id}/commands/{command}` | Receipt принятой команды |
| POST `/v1/projects/{id}/runs` | `command_id`, `revision`, `sheet_id`, `cell_id`, `action`: run/run_all |
| GET `/v1/projects/{id}/runs` | Согласованные head, список работ и event watermark |
| GET `/v1/projects/{id}/registry` | Краткие metadata работ/runtime без result/live JSON для GUI polling |
| GET `/v1/projects/{id}/events?after=N` | События после cursor, до 1000 за запрос |
| GET `/v1/runs/{id}` | Статус, provenance, terminal/live summaries |
| GET `/v1/runs/{id}/presentation` | Полная terminal presentation |
| GET `/v1/runs/{id}/live` | Последняя binary live presentation |
| POST `/v1/runs/{id}/stop` | `command_id`, `runtime_epoch`, необязательный `force` |
| POST `/v1/projects/{id}/restart` | `command_id`, `sheet_id`, `runtime_epoch`; активный Run сначала нужно остановить |
| DELETE `/v1/projects/{id}` | `command_id`; tombstone и завершение принадлежащих проекту runtime |

HTTP 409 означает конфликт ревизии, busy, stale epoch или необходимость явного restart. HTTP 422 означает неподдерживаемую семантику preview. Запросы ограничены 96 MiB, документ — 7 MiB, файл — 16 MiB, bundle — 64 MiB, число активных runtime — 8.

## Следующие границы

Snapshot публикуется в порядке: запись файлов → `fs.sync` файлов и каталогов снизу вверх → rename в immutable revision → долговечная запись manifest → `fs.sync` каталога revisions → commit head/receipt/events в SQLite. Ошибка IO до commit оставляет прежний head и позволяет повторить ту же команду; неиспользованное дерево может остаться до будущего GC. При создании state root синхронизируются также его каталоги и записи новых предков. Это использует гарантии `fsync` файловой системы и накопителя; физическое отключение питания в тестах не моделируется.

Нужны раздельные saved/draft baselines и Apply immutable environments, загрузка dependency/native bundles, typed inputs и idle Watch pump, серверные расписания, writer lease, streaming, storage retention/GC, quotas и полное helper-process tracking. Перенос heap/GPU context после смерти узла не реализован; продолжение вычислений требует явных checkpoints.
