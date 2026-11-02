# Аудит Notebook перед tech preview — 2026-10-28

**Статус после исправлений:** пять описанных ниже дефектов исправлены в workspace; см. [реализацию, регрессии и ограничения проверки](notebook-tech-preview-fixes-2026-10-28.md). Остальная часть этого документа сохраняет исходные наблюдения и доказательства до исправлений.

**Вывод: текущий workspace пока не готов к внешнему tech preview.** Найдены четыре P1-дефекта и один P2-дефект с воспроизведениями. Первые четыре затрагивают содержимое документов, повторное выполнение команд, остановку процессов и достоверность результатов. Пятый оставляет серверное расписание в невосстановимом через Start состоянии после временной ошибки хранения.

Проверены Swift app, native notebook-core, durable Core и remote agent/gateway/CLI. Аудит относится к **текущему рабочему дереву**, включая незакоммиченный перенос core, а не только к HEAD `082c8eb2c26aa0ca724fa3be4226755b48977024`. Language HEAD: `77650e1e73bae5505d819e1d95f037be7592e19d`. SHA-256 основных проверенных файлов: [manifest](../evidence/2026-10-28/tech-preview-audit/manifest.json).

## 1. P1 — Старый remote-export меняет содержимое уже открытого другого notebook

**Код:** `tools/notebook-macos/NotebookModel.swift:406–415`, `:533–539`, `:1521–1548`.

`open()` ставит замену native handle в serial worker queue, но отключает прежний remote controller и меняет `documentIdentity` только в completion. Во время открытия старый async remote flow ещё может поставить `export(edits:)` вслед за `worker.open()`. Export применяет захваченные черновики к `self.handle`, который к этому моменту уже принадлежит новому notebook. Проверка identity находится в completion и отменяет только публикацию результата: изменение native document уже произошло.

Для двух notebook с обычными одинаковыми `sheet:main` / cell `1` воспроизведение дало:

```text
В A набран черновик: 999
В B исходный текст: 2
old_callback_rejected = true
displayed_B_before_save = "2\n"
save_succeeded = true
B_source_after_save = "999\n"
```

То есть интерфейс B ещё показывает `2`, а последующее Save All сохраняет в B текст из A. Harness детерминированно задаёт опасный порядок вызовов настоящей Swift-модели; это не автоматизация кликов и не вероятностный нагрузочный тест.

**До релиза:** привязать все queued document mutations к поколению/handle документа и проверять принадлежность **на worker queue до изменения**. Начало смены документа должно инвалидировать старые remote operations. Одного guard в UI completion недостаточно; проверить также restore/import inputs/result.

**Критерий закрытия:** старый export после enqueue открытия B не изменяет B ни в памяти, ни при Save All; аналогичный тест покрывает failed open и повторное открытие.

## 2. P1 — HTTP 5xx уничтожает pending ticket принятой команды, повторный Run выполняется заново

**Код:** `tools/notebook-macos/NotebookRemote.swift:609–612`; тот же шаблон — `:447–448`, `:467–469`, `:517–520`. Источник неопределённости: `tools/notebook-remote/server.s:133–136` и `packages/notebook-core/src/notebook/core/client.s:16–24`.

Клиент трактует любой `NotebookRemoteFailure.status > 0` как окончательный отказ и удаляет pending Run/inputs вместе с приватным ticket. Но gateway возвращает 503 при потере ответа IPC, в том числе после принятия/commit команды агентом. Положительный HTTP status не доказывает, что команда не была принята.

На настоящем `NotebookRemoteController` с fault-injection CLI: первый запрос записан как принятый, затем возвращён 503. Наблюдение:

```text
first_call_succeeded = false
pending_after_503 = false
accepted_command_count = 2
distinct_command_ids = 2
```

Повторный Run создаёт новый `CommandId`; механизм server receipts уже не может защитить от повторных внешних эффектов. Тест моделирует потерю ответа на границе CLI; реальный сетевой таймаут после commit отдельно не инжектировался. Возможность такого 503 подтверждена обработчиком gateway.

**До релиза:** сохранить pending command при 5xx, сетевых ошибках и неоднозначном ответе; восстановление выполнять через receipt и исходный CommandId. Очищать ticket только после подтверждённого результата или определённого отказа. Применить правило и к inputs/actions/services.

**Критерий закрытия:** после принятия команды и последующего 503 reconnect находит прежний receipt; повторный UI Run не создаёт вторую команду до разрешения первой.

## 3. P1 — Force Stop завершает worker, но оставляет его внешние процессы работающими

**Код:** `packages/notebook-core/native/process.cpp:137–141`; общий путь используется local и remote. `packages/notebook-core/native/execution.cpp:126–130` ждёт только завершения worker. Monitor внешнего `system.command` находится внутри worker (`sputnik-lang/runtime/system.cpp:633–678`).

На отдельном настоящем native agent запущена ячейка с разрешённым `process.spawn=/bin/sh` и scoped `.capture(timeout: 30.0)`. Shell создаёт start marker, ждёт четыре секунды и пишет второй marker. После появления первого marker выполнен Force Stop:

```text
terminal_state = "force-stopped"
child_finished_at_stop = false
child_continued_after_stop = true
```

Это обычный дочерний процесс, без daemonize/setsid и без попытки обойти ограничения. После убийства worker исчезает и monitor, который мог бы остановить child. В реальной задаче внешний процесс может продолжать обучение, запись файлов или сетевые операции после подтверждённой остановки.

**До релиза:** обеспечить владение деревом внешних процессов вне убиваемого worker: supervisor/контейнер исполнения/платформенный механизм с учётом того, что `system.command` умеет создавать собственную process group. Не публиковать полную остановку только по `waitpid(worker)`. Пока такой гарантии нет, ограничить доступную в preview возможность запуска внешних процессов.

**Критерий закрытия:** тесты Force Stop, аварии worker и уничтожения host подтверждают прекращение scoped children и их побочных эффектов на macOS и Linux.

## 4. P1 — Авария нового board action оставляет прежний успех как актуальный

**Код:** `tools/notebook-macos/NotebookRemote.swift:741–754`; отображение использует `NotebookP1Model.swift:13–14`, `:50` и `NotebookExecutionControlsView.swift`.

`refresh()` выбирает terminal runs только при `run.presentation == true`. У `interrupted`/`force-stopped` presentation может отсутствовать. Новый terminal run тогда исключается из обработки; прежний успешный остаётся в `invocationResults`. Staleness определяется revision/input version, которые могут не измениться между запусками.

На настоящем Swift controller с детерминированным registry: Run 1 завершился с `42`, Run 2 той же action/revision/inputs имеет `state=interrupted`, `has_presentation=false`:

```text
latest_run_state = "interrupted"
displayed_ok = true
displayed_result = "42"
displayed_stale = false
```

Это смешивает предыдущий результат и исход последней попытки. Ошибка уже видна в registry, но не попадает в состояние action result.

**До релиза:** определять последний run по owner независимо от наличия artifact; получать terminal error/status для последней попытки, предыдущий artifact хранить отдельно с явной меткой Previous. Проверить также terminal run без result/presentation после рестарта agent.

**Критерий закрытия:** success → interrupted/force-stopped/ошибка подготовки показывает исход последней попытки; сохранённое `42` не выглядит её успешным результатом.

## 5. P2 — Ошибка SQLite навсегда оставляет Periodic Work в running без Run

**Код:** `packages/notebook-core/src/notebook/core/services.s:130–143`, `:117–122`, guard в `configure()`.

`dispatch(state)` меняет общий объект из `@states` — выставляет `running=true`, `run_id`, убирает deadline — до транзакции `persist_run`. При rollback это изменение памяти остаётся. Обработчик `tick()` выключает `enabled`, но не сбрасывает `running` и не восстанавливает предыдущую версию state.

Воспроизведено на настоящем agent: Start с `run_immediately=false`, внешний SQLite `BEGIN IMMEDIATE` на 7 секунд при `busy_timeout=5.0`, затем снятие блокировки:

```text
enabled = false
running = true
status = "database is locked"
runs = []
повторный Start → HTTP/domain 409 "service is already running"
```

Тест использует временную БД. Состояние не исправляется после снятия блокировки; новый Start/Once запрещён. Требуется перезапуск agent, затрагивающий другие runtime.

**До релиза:** готовить копию состояния, публиковать в `@states` только после commit; при ошибке оставлять service доступным для явного retry. Проверить согласованность также в `completed()`/pause paths, где состояние меняется до записи.

**Критерий закрытия:** после SQLITE_BUSY service не заявляет несуществующий Run и возобновляется без рестарта agent. Отдельно покрыть ошибки записи.

## Условия выпуска помимо пяти дефектов

1. **Готовый macOS artifact пока development-only.** `codesign` показывает `Signature=adhoc`, а packaging всегда использует `--sign -` (`package-app.sh:117–122`). В текущем bundle `LSMinimumSystemVersion=26.0`, архитектура только arm64; link logs подтверждают runtime и dylib, собранные для macOS 26.0. Требуется определить реальную матрицу preview, собрать зависимости под выбранный deployment target и проверить распространяемый архив на чистой целевой машине. Для обычной внешней раздачи нужен отдельный release signing/notarization workflow; текущая инженерная документация также прямо относит это к незавершённой подготовке релиза. Это проверка существующего artifact, не утверждение, что упаковщик неправильно выставил минимальную ОС: он как раз учитывает зависимости. [Доказательство](../evidence/2026-10-28/tech-preview-audit/bundle-inspection.txt).

2. **Remote хранение и polling не ограничены историей сервиса.** **Обновление:** реализованы иерархические policy, ограниченный registry, retention, квоты и временные сессии; см. [описание текущего поведения](notebook-resource-policies.md). Далее сохранено исходное наблюдение аудита. `retention=none/tail` ограничивает только `services.history`. Каждый Run сохраняет frozen document в `run_inputs`, итоговый `.bin`, возможно `.live.bin`, rows/events; registry возвращает все runs/runtime records и вызывается Swift-клиентом каждые 0.6 секунды. GC касается environment/project package directories, а не `runs`/`revisions`. Для продолжительно работающего preview нужны лимит диска/retention и ограниченный registry с отдельной историей, либо явный запрет длительных расписаний до их реализации. Это вывод по коду (`core.s:573–583`, `:643–645`, `:892–902`, `services.s:155–160`), не результат многочасового stress-теста. Нельзя удалять receipts произвольно, нарушая гарантию дедупликации.

## Что проверено и где границы

Успешно выполнены:

- `make -j4 test-notebook-core test-notebook-worker test-notebook-remote`: core API VM/full-native, package boundary, readiness, worker/worker-host, cancellation, run tasks, remote command VM/full-native и **46 remote integration tests**.
- Пересборка и запуск `notebook_macos_model_tests`, `notebook_macos_bridge_tests`, `test-notebook-library`.
- Два целевых agent-воспроизведения и три целевых Swift-воспроизведения выше. Проверочный dependency-failure scenario корректно вернул `failed` и в findings не включён.
- Статический разбор путей сохранения, восстановления, receipt/revision handling, worker grants, uploads/path checks, package/environments и packaging.

Первый запуск сетевых тестов внутри sandbox остановился на запрете `listen`; повторный запуск с разрешением прошёл. Это ограничение окружения не считается дефектом продукта.

Полный UI-suite и ручной прогон всех компонентов не выполнялись; Linux, чистая машина/другая macOS, notarized distribution и длительный нагрузочный прогон в этом аудите не проверены. Рабочий remote server не трогался. Production-код не менялся: добавлены этот отчёт, воспроизведения и доказательства.

Все материалы: [evidence README](../evidence/2026-10-28/tech-preview-audit/README.md). Рекомендуемый порядок исправления: **1 → 2 → 3 → 4 → 5**, затем проверка artifact и ограничений хранения. Успешные штатные тесты не покрывают приведённые fault/interleaving cases; их стоит превратить в постоянные regression tests вместе с исправлениями.
