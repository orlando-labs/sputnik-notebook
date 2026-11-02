# Аудит действий notebook в remote-режиме

Продолжение от 2 ноября: [исправления R1–R5 и remote-регрессии](notebook-remote-actions-fixes-2026-11-02.md). Ниже сохранён исходный снимок результатов аудита до исправлений.

Дата: 1 ноября 2026. Проверено текущее рабочее дерево, включая незакоммиченные изменения. Область: **macOS Notebook → HTTP/CLI → Remote Core → worker**. Веб-клиент рассмотрен отдельно как второй адаптер того же Core. Наличие renderer в вебе не считается доказательством поддержки действия в macOS remote.

**Полного паритета с This Mac нет.** Инвентаризация охватывает **44 команды C API, 35 инструментов палитры / 33 сохраняемых kind**, а также команды подключения, остановки, расписаний, зависимостей и истории вне C API. Основные пробелы находятся в управлении invocation runtime, передаче выбранного изображения и интеграции desktop-клиента с серверными media/history API.

Аудит не меняет реализацию. Статическая поддержка, динамическое воспроизведение и исторические acceptance разделены ниже. Изолированные проверки создают только временный локальный сервер; рабочий SSH-сервер не изменялся.

## Обнаруженные ошибки

### R1 · P1 · Restart у Action / Periodic Work успешно завершает локальный no-op

В `NotebookExecutionControlsView.swift:25–28` Restart для action/service вызывает `perform("periodic_dispose")`. В remote-ветке `NotebookModel.perform` нет обработки этой команды. Она доходит до локального `command_impl`, где очищает только `notebook->periodic` (`packages/notebook-core/native/notebook.cpp:868–875`). Серверный invocation принадлежит Core, поэтому эта локальная таблица его не содержит.

Следствие: пользователь видит успешное действие, но epoch и module heap на сервере сохраняются. После Force Stop такой Restart не выводит invocation из состояния, требующего явного restart. Даже обычный Restart не сбрасывает накопленное состояние функции.

Воспроизведение: экспортированная функция со счётчиком возвращает `1`; после `periodic_dispose` следующий вызов возвращает `2` с тем же epoch. Исправление должно адресовать фактического владельца invocation через server runtime restart и подтверждать серверный результат. Веб уже передаёт конкретный Run в `restartInvocation` (`frontend/src/execution.ts:252`), backend разрешает его в runtime owner.

### R2 · P1 · Execution Controls не адресуют Stop / Force Stop выбранному action/service

Кнопки Stop / Force Stop вызывают общий `model.stopExecution()` без board/component/run (`NotebookExecutionControlsView.swift:20,25`). Модель передаёт только controller sheet (`NotebookModel.swift:938–946`), а `NotebookRemote.stop` выбирает **последний активный Run**, чей sheet или controller совпал (`NotebookRemote.swift:665–667`).

При двух параллельных actions на одном контроллере невозможно указать прежний Run. Дополнительно `executingTargetID` хранит только последнюю активную board-команду всего проекта (`NotebookModel.swift:696–698`), поэтому targeted controls другого активного invocation могут выглядеть неактивными. Для sheet controls совпадение по controller также допускает остановку invocation вместо собственного sheet Run.

Воспроизведение: запустить A, затем B одного board; общий Stop отменяет B, A остаётся активным. Само поведение глобального Stop может быть допустимым, но оно не реализует выбранную цель компонента Execution Controls. Нужна передача точных RunId + epoch по board/component или по sheet owner. Веб-компонент уже вызывает `runtime.stop(run)` для конкретной цели (`NotebookBoardCommand.vue`).

### R3 · P1 · Carousel показывает выбранный кадр, а удалённый Run читает прежний

`selectImage` выполняет локальный `image_select` (`NotebookModel.swift:1140–1141`). В `ProjectTabs::select_image` меняется `session.project_images.selected`; сохраняемое поле `image_selection` не меняется (`../sputnik-lang/tools/isputnik/tabs.cpp:644–658`). Обычный remote sync экспортирует документ и файлы, а не локальный session index. Отдельной remote-команды selection в desktop-транспорте нет.

Следствие: просмотр и `notebook.read_image(channel)` расходятся. Загрузка/reorder коллекции через `image_edit` сохраняет выбранный индекс, но последующая навигация Previous/Next уже не передаёт его серверу. Нужен явный принятый сервером выбор с корректной provenance либо сохранение выбора в публикуемом snapshot до Run.

Подтверждено на реальном Core: после выбора desktop index `1` следующий серверный Run возвращает caption `"First"` вместо `"Second"`.

### R4 · P2 · Date / Time Input отключён независимо от возможностей сервера

Apply содержит безусловный `.disabled(... || model.remote.isSelected || ...)` (`NotebookRangeDateView.swift:169–172`). При этом его обработчик уже использует `setProjectInputs`, который имеет remote-маршрут и серверную batch validation. String-параметр можно изменить другим Input/Form, но DatePicker не позволяет принять его в remote.

Это пробел UI, а не отсутствие String/project inputs в Core. Условие нужно связать с connection/busy/pending/capability, аналогично другим inputs, и проверить timezone/ISO-8601 round trip через удалённый worker.

### R5 · P2 · Pin / Rename / Delete Run работают только с локальной копией истории

UI вызывает `NotebookRunHistory.pin/rename/remove`; эти методы изменяют `.notebook-history` (`NotebookRunHistory.swift:135–137`). `run.annotate` / `run.delete` не представлены в HTTP gateway и CLI desktop-клиента, хотя есть в Core и используются вебом. Scalar restore прямо отключён в remote (`NotebookRunHistory.swift:263`, `NotebookRunHistoryView.swift:35`).

Последствия: имена/pins не разделяются между клиентами; локальный pin не защищает результат от серверного retention. Удалённая локальная запись может восстановиться после reconnect из terminal presentation. Desktop получает compact registry с текущими heads и не загружает всю историю через пагинацию `runs`; на новом клиенте полный серверный журнал не восстанавливается.

Подтверждено на реальном Core: локальная запись удаляется, после reconnect та же запись появляется снова. Probe содержит Run History component: без него desktop намеренно не записывает локальную историю.

Нужны серверные history-команды и пагинация, а также явное разделение удаления серверного Run и удаления локального кеша. Restore следует проводить через принятые scalar input batches с проверкой текущих revision/version, не через локальный `restore_inputs`.

## Матрица всех 44 команд

«Редактирование + sync» означает отсутствие локального выполнения кода и публикацию полного snapshot. Это не обещание немедленной установки новой ревизии в живой worker: для исполнения используются явный Run / Apply inputs; изменение module environment требует Restart.

| Команда | macOS remote | Путь / ограничение |
| --- | --- | --- |
| `select` | Да, клиент | Навигация; затем обычный sync metadata. |
| `source` | Редактирование + sync | Буферы листов и модулей входят в snapshot. |
| `rich_source` | Редактирование + sync | Text source и formatting, включая несохранённые drafts. |
| `watch` | Редактирование + sync | Авторство режима; новый draft сам не исполняется. |
| `add_cell` | Редактирование + sync | Структура листа. |
| `add_text` | Редактирование + sync | Структура/text metadata. |
| `delete_cell` | Редактирование + sync | Ссылки/ID проверяет общий loader. |
| `move_up` | Редактирование + sync | Порядок ячеек. |
| `move_down` | Редактирование + sync | Порядок ячеек. |
| `set_cell_id` | Редактирование + sync | Общая проверка Hard ID. |
| `new_sheet` | Редактирование + sync | Новое имя/ID; без инициализации runtime. |
| `rename_sheet` | Редактирование + sync | Авторское имя листа. |
| `new_module` | Редактирование + sync | Файл включается в bundle; отдельный remote module-tab Run отсутствует. |
| `auto_import` | Редактирование + sync | Меняет module environment; нужен Restart. |
| `save` | Да | Сохранение локального notebook и последующий sync; успех Save не равен подтверждению remote sync. |
| `save_all` | Да | Все локальные источники; remote revision публикуется отдельно. |
| `save_board` | Редактирование + sync | Включая вложенные panels, settings, presets, service definitions. |
| `save_cell_ui` | Редактирование + sync | Pre/post components и определения cell inputs. |
| `new_input` | Редактирование + sync | Определение/default, а не отдельный accepted value. |
| `delete_input` | Редактирование + sync | Изменение схемы; дальнейшие accepted values валидирует Core. |
| `retain_cell_results` | Да | Настройка хранения отображаемых результатов, не серверный pin/retention. |
| `resource_policy` | Да | Document policy + отдельный `set_resource_policy` при `desktop_policy`; Core ограничивает исполнение. |
| `run` | Да, только sheet code cell | CLI `run` → `run.start`; source/revision/receipt. |
| `run_all` | Да, один sheet | Все code cells выбранного sheet; не все sheets проекта. |
| `set_input` | Да | `set_inputs` → `project.inputs.set`. |
| `set_inputs` | Да | Атомарный project batch, accepted version, Watch/Manual semantics. |
| `set_cell_inputs` | Да | `cell.inputs.set`; общий accepted-state version. |
| `action_run` | Частично | Изолированный server invocation и результаты есть; Stop/Restart — R1/R2. |
| `periodic_run` | Частично | Run Once через `service.configure`; lifecycle controls — R1/R2. |
| `restart_worker` | Да, sheet | Remote `restart`; `perform` вызывает completion до серверного ответа, результат нужно брать из remote state. |
| `worker_grants` | Через другой API | UI вызывает `configureWorker` → `worker.configure`; прямой `perform` в remote заблокирован C API. |
| `worker_environment` | Через другой API | Та же worker settings transaction; server path/environment, не локальный путь Mac. |
| `watch_run` | Принадлежит серверу | Локальный запуск заблокирован; idle Watch выполняет агент без GUI. |
| `periodic_tick` | Принадлежит серверу | Прямой desktop tick отвергается; timer/dispatch в агенте. |
| `periodic_dispose` | **Ошибка R1** | Локальный no-op вместо server restart. |
| `image_select` | **Ошибка R3** | Session index остаётся только на Mac. |
| `image_edit` | Частично | Локальный media bundle → full snapshot sync; нет desktop `media.accept`/accepted receipt. |
| `audio_edit` | Частично | Локальный asset/manifest → full snapshot sync; live client Apply и remote commit не одна операция. |
| `component_data_edit` | Нет из remote UI | Shared table selection, image/audio annotation editing отключены. Local command не является remote transaction. |
| `restore_inputs` | Нет из remote UI | Внутренне используется для зеркалирования принятого сервером значения; не реализует удалённый history restore. |
| `apply` | Нет | Явное сообщение «sync modules and restart»; кнопка Apply Environment отключена. |
| `add_dependency` | Нет для directory links | Локальная привязка может сохраниться, но Core Run возвращает 422 для непустого document.dependencies. Registry packages — отдельный поддерживаемый путь. |
| `remove_dependency` | Ограничено | Локальный unlink metadata; не remote package remove. В Dependencies remote Unlink отключён. |
| `trust_native` | Внутренняя client policy | Локальный consent flag; не отдельная remote transport operation. Worker grants/native packages проверяются своим путём. |

Источник и воспроизводимая проверка полноты: [inventory.json](../evidence/2026-11-01/remote-action-audit/inventory.json), [inventory.mjs](../evidence/2026-11-01/remote-action-audit/inventory.mjs). Скрипт проверяет, что каждой строковой команде `command_impl` соответствует классификация; новые команды требуют обновления аудита.

## Операции вне command_impl

| Действие | Поддержка / граница |
| --- | --- |
| Servers: direct HTTPS / loopback HTTP / SSH tunnel | Реализованы profile/token/tunnel, capability negotiation; системный SSH key/known host. |
| This Mac / выбрать сервер / Disconnect / закрыть приложение | Реализовано; disconnect не останавливает принятую работу. |
| Reconnect / открыть notebook / восстановить Run | Registry + source document + live/terminal presentation; без replay ячеек. Не восстанавливает heap после смерти агента. |
| Sync / autosync / Publish local version | Immutable upload, CAS, receipt; конфликт требует явного выбора версии. |
| Projects: список / Download | Реализованы bundle checkout и remote binding. Это не перенос живого heap. |
| Stop / Force Stop выбранного sheet | Серверный Run/epoch; при наличии actions этого же controller есть R2. |
| Start / Pause / Run Once / Clear service history | `service.configure` с durable receipts. Pause оставляет текущий вызов; Stop отменяет его и паузит schedule. |
| Server periodic после скрытия board/закрытия GUI | Продолжается; local `pause_when_hidden` не управляет серверным lifetime. После agent restart — явный Start. |
| Worker Settings / Clear grants / Apply and Restart | Проверка policy/version/epoch, запрет busy workers, retirement invocation worlds. |
| Registry package catalog / versions / variants / install / remove | Реализованы на execution host, с jobs/logs и retirement runtime. Directory dependency links сюда не входят. |
| Python / Ruby dependency files, lock / prepare environment | Реализованы management API; сами interpreters нужны только соответствующим foreign notebooks. Environment apply пересоздаёт worker. |
| История: inspect / export / сравнение / CSV | Работает для локально записанных/recovered snapshots. Вся server history и shared metadata не подключены — R5. |
| Таблица: sort / filter / copy / export | Клиентские действия над captured result работают. Shared accepted row selection отключён. |
| Audio playback / seek / waveform, image/plot save/export | Клиентские действия над скачанными presentation bytes. Произвольный server file access этим не предоставляется. |
| Unused media archive | Отключён в remote (`NotebookBookSettingsView`, `NotebookMediaAssetsView`). |
| Module tab Run / Apply modules без Restart | Отсутствуют; module source можно редактировать и синхронизировать. |
| Произвольные output files / artifact download | Desktop Artifact Browser целиком unavailable. Bundled media/presentation не означают общую выгрузку server filesystem. |

## Все инструменты палитры

«Есть» в этой таблице означает присутствующий путь rendering/interaction; индивидуальная динамическая проверка каждой настройки в этот аудит не входит. Метки неполной поддержки учитывают конкретные действия, а не только наличие компонента на экране.

| Инструмент | macOS remote | Ограничение |
| --- | --- | --- |
| Tabs | Есть | Авторство/layout локально, document sync. |
| Split View | Есть | Сохранение fraction + sync; изменение выключено при active remote work. |
| Group / Accordion | Есть | Локальный layout/view state. |
| Input | Есть | Accepted project inputs. |
| Config Editor | Есть | Existing `input` kind; validation/format/import/export на клиенте, Apply через inputs. |
| Parameter Form | Есть | Атомарный batch. |
| Parameter Presets | Есть | Definitions через board save; Apply через project inputs. |
| Range Input | Есть | Общая typed range validation. |
| Date / Time Input | **Apply отключён** | R4. |
| Audio Input / Recorder | Частично | Локальная запись/asset + full bundle sync; нет атомарного desktop media acceptance. |
| File / Dataset Input | **Отключён** | Явная заглушка вместо remote transfer. |
| Action Button | Частично | Invocation есть, targeted lifecycle — R1/R2. |
| Execution Controls | **Ошибки** | Invocation Restart / targeted Stop — R1/R2. |
| Text Cell | Есть | Rich text/Markdown и captured variables. |
| Text / Value | Есть | Captured result/locals с freshness. |
| Metric / KPI | Есть | Captured metrics/scalar values. |
| Status / Alert | Частично | Remote status есть; invocation target зависит от одного `executingTargetID` — R2. |
| Log Viewer | Есть | Captured/live output и локальные фильтры. |
| Artifact Browser | **Отключён** | Явная заглушка remote transfer. |
| Result Inspector | Есть | Captured Inspect/Pretty/table/Find. |
| Data Table | Частично | Просмотр/sort/filter/export есть, shared accepted selection отключён. |
| Task Monitor | Есть | Общие live/terminal telemetry DTO; GPU telemetry не предоставляется. |
| Run History | Частично | Локальные snapshots/labels; R5, remote restore отключён. |
| Experiment Compare | Частично | Сравнивает доступные локальные snapshots; R5. |
| Image Annotator | **Редактирование отключено** | Saved annotations сохраняются; remote binding disabled. |
| Audio Annotator | **Редактирование отключено** | Saved annotations сохраняются; remote binding disabled. |
| Audio Player | Есть | Скачанный audio DTO и клиентский playback. |
| Progress | Есть | Общая live/terminal presentation. |
| Stopwatch | Есть | Общая live/terminal presentation. |
| Figure | Есть | Captured figure/plot scene, локальные export/zoom. |
| Live Chart | Есть | Live/terminal chart DTO, authored series. |
| Image | Частично | Rendering/export и full-bundle edit есть; annotations отключены. |
| Image Carousel | **Ошибка выбора** | Навигация расходится с remote read_image — R3. |
| Run Button | Частично | Sheet cell remote Run есть; кнопка дополнительно disabled при `environment_stale`, требуется Restart/обновление состояния. |
| Periodic Work | Частично | Server schedule есть; invocation lifecycle — R1/R2. |

## Core, desktop remote и веб — разные уровни поддержки

В Core уже есть `media.accept`, `media.source`, `run.annotate`, `run.delete`, paginated `run.list`. Веб вызывает их через local RPC; desktop использует HTTP gateway/CLI, где media/history mutations ещё не подключены. Поэтому добавление реализации в Core само по себе не закрывает desktop parity.

Текущий веб-инвентарь содержит все 35 tools / 33 kinds. Это подтверждает coverage kind, но не равенство каждого действия с This Mac. Веб уже имеет target-specific Stop/Restart, File/Audio/Image managed uploads, shared selection и оба annotator, server history labels/delete и scalar restore по отдельному scope. Ограничения остаются для directory dependencies, самостоятельного module-tab Run, произвольных external/generated artifacts и восстановления heap/GPU после смерти процесса/узла. У веб Artifact Browser доступ ограничен подтверждёнными файлами captured revision bundle.

Источник сравнения: [актуальная web acceptance](../evidence/2026-10-31/notebook-web-runtime-observations/README.md), а также `NotebookBoardCommand.vue`, `execution.ts`, `NotebookSharedTable.vue`, `NotebookImageAnnotator.vue`, `NotebookAudioAnnotator.vue`, backend `inputs.s` / `run_history.s`. Старое утверждение об отсутствии web Status/Artifacts/Task Monitor из первой версии parity-аудита уже не актуально.

## Проверки и оставшиеся acceptance-пробелы

Машинный inventory: 44/44 commands классифицированы, 35 palette tools / 33 kind. SHA-256 основных проверенных исходников сохранены рядом с inventory, чтобы HEAD не подменял идентичность грязного рабочего дерева. Четыре runtime-воспроизведения R1/R2/R3/R5 завершились успешно; R4 установлен статически по условию disabled. Native remote integration suite завершился с кодом 0, включая десять функциональных групп; launcher checks прошли в VM и native.

Динамические результаты, команды воспроизведения и точные binary hashes: [evidence README](../evidence/2026-11-01/remote-action-audit/README.md). Audit probe использует текущие Swift model sources и реальный изолированный native Core/worker.

Нет единого теста, перечисляющего все desktop-команды в remote mode и проверяющего серверный эффект каждой. Существующие remote API и Swift model suites покрывают Run, inputs, Watch, actions, schedules, cancellation, reconnect, grants и зависимости, но не доказывают parity всех компонентов. Основные отсутствующие проверки:

1. Две одновременные actions/services + собственный sheet Run: target-specific Stop, Force Stop, Restart, status и восстановление после Force Stop.
2. Carousel Next/Previous → remote read_image → reconnect с тем же accepted выбором.
3. DatePicker timezone/ISO-8601 → Apply → server worker → reconnect.
4. Shared selection и image/audio annotation Apply с CAS, stale-source rejection, lost reply и reconnect через desktop transport.
5. History pagination с нового клиента, shared Pin/Rename/Delete, server retention и scope-checked restore.
6. Полная 35-tool remote acceptance с реальным SwiftUI, включая disabled/error states; свежая SSH/Linux проверка конкретного развёрнутого релиза.

Приоритет исправлений: **сначала R1–R3**, затем подключение desktop к имеющимся media/history API и Date Apply. Отдельные product decisions нужны для module-tab Run, Apply без Restart и directory dependency bundles; их отсутствие уже явно отражено в контракте.
