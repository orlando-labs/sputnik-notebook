# P2: история, runtime и дополнительные компоненты

## Run History / Experiment Compare

Плитки Display используют общий `.notebook-history` внутри проекта. Добавление Run History или Experiment Compare включает сохранение явных Run/Run All/Apply для соответствующего листа. Снимок не является новым текущим результатом ячейки и не исполняет код при просмотре.

Сохраняются источники листов и модулей с SHA-256, принятые scalar inputs, cell inputs, selection и annotations, media inputs, зависимости, время/backend/status, локальные числовые метрики, result/pretty/table, logs и portable displays. PCM stream становится WAV retained диапазона. Снимки включают stale-флаги outputs, поэтому старый неисполненный Manual output не выдается за новый результат. До 16 MiB media входят в один snapshot; пропуски обозначены в инспекторе. Размер записи ограничен 32 MiB.

Retention: 20 последних неприкреплённых записей + до 10 pinned, общий бюджет 256 MiB. Pin, Rename, Delete и JSON export явные. Повреждённые/неподдержанные записи не исполняются; ошибка чтения показывается рядом с историей. Symlink history member отклоняется. Фоновый Watch и Periodic Work не засоряют эту историю: Periodic Work сохраняет собственные записи.

Restore scalar parameters валидирует всю партию project/cell inputs до публикации одного immutable снимка. Неверная дата, range-инвариант, изменённый тип или удалённое определение отклоняют всю партию. Восстановление инвалидирует потребителей без запуска. Исходники и audio assets просматриваются отдельно; кнопка не подменяет их. Авторские defaults не переписываются. Restore пока доступен в local mode.

Experiment Compare показывает параметры, числовые метрики и длительности с абсолютной delta. Сравнение не назначает предпочтительность метрики автоматически. Есть CSV export, исходные snapshots открываются отдельно.

Remote core `run_document` возвращает `execution_document` из immutable `run_inputs`, включая принятые cell inputs конкретного запуска. Клиент запрашивает его для терминального результата и сохраняет epoch/revision. Старый core даёт явную пометку о неполном provenance. Восстановленные remote runs имеют стабильную identity и не дублируются при повторной доставке. Это не снимает имеющиеся ограничения remote core на dependency bundles и project inputs.

## Runtime Status, Task Monitor и live logs

Status / Alert получил target `runtime`. Он показывает Local/Remote, connected/disconnected, preparing/running/draining/restarting и revision conflict, последний контакт и environment generation/epoch при наличии. CPU/RAM относятся к процессу worker. CPU — разница `getrusage` за реальный интервал, может превышать 100% при нескольких ядрах. Resident RAM читается через Mach на macOS и `/proc/self/statm` на Linux. GPU не измеряется и отображается как unavailable. Старый snapshot не выдается за текущую нагрузку: UI показывает время последнего sample.

Task Monitor показывает реальные run registrations, parent/child связи, состояние, длительность, место создания и ошибки. Это дерево runtime membership, включая foreign callbacks, а не progress channels. Идентичность не переносится между запусками. Удерживаются до 512 записей, при сокращении показывается счётчик пропущенных. Отмена остаётся действием всего Run: отдельная task-cancel capability не заявлена.

Log Viewer и обычный output листа получают stdout/stderr во время Run. У каждого cell stream bounded tail: 256 KiB и 2,048 events. General-purpose text buffers сохраняют прежнюю семантику. Утраченное начало явно отмечено `truncation` event. Порядок stdout/stderr сохраняется по runtime sequence. Worker передаёт заменяемый retained snapshot, поэтому coalescing/reconnect не дублируют строки. Terminal flush сохраняет вывод после drain дочерних задач.

Presentation v15 / private protocol v17 добавляет лог-снимки и типизированную telemetry. Сохранённые v14/v13/v12/v11 читаются отдельно по их схемам.

## Range и Date / Time Input

Range Input и обычный Input с параметром `range` поддерживают два режима `control`: `style: "slider"` — одна шкала с двумя бегунками и общими `minimum`/`maximum`; `style: "range_sliders"` — отдельные слайдеры с `start_minimum`/`start_maximum` и `finish_minimum`/`finish_maximum`. Оба сохраняют `finish >= start`, включая равенство. `control.step` задаёт шаг перемещения бегунков отдельно от `step` значения Range. Backend проверяет пределы и порядок при Apply, Presets, Restore и изменении cell inputs. Для IntRange пределы слайдеров и шаг перемещения целые, в пределах ±(2^53−1); ручной ввод сохраняет полную точность Int64.

Range Input связывает один project input типа `range` через `input`. Значение хранится как `{start, finish, inclusive_end, step}`; `notebook.input("some_range")` возвращает настоящий Sputnik Range, например `(0...15:3)`. Редактор задаёт начало, конец, Inclusive (`..`) / Exclusive (`...`) и ненулевой шаг. Поддерживаются точные Int64, дробные и убывающие диапазоны; IntRange требует целого шага. Apply публикует весь диапазон одним значением. Presets и Restore используют ту же проверку. Старые `range_lower`/`range_upper` при открытии преобразуются в отдельный Range input; исходные числовые определения сохраняются для существующего кода.

Date / Time Input связывает String input. `date_mode`: `date` или `date_time`; `date_time_zone` — IANA display zone, default UTC. Хранится `YYYY-MM-DD` либо `YYYY-MM-DDTHH:MM:SSZ`. Пустая строка означает отсутствие принятой даты. Календарь и leap year проверяются backend; Naive/offset timestamps не принимаются вместо объявленного UTC. Apply/Reset относятся к draft. Remote применение ограничено имеющимися возможностями project-input API.

## Split View

Layout-компонент владеет ровно двумя независимыми panel grids. `split_axis`: horizontal/vertical, `split_fraction`: 0.1–0.9, `split_min`: 48–1,024 points. Divider меняет локальный runtime layout, Save divider position сохраняет authored default. Дочерние компоненты и их bindings сохраняются. Узкий контейнер становится вертикальным scroll layout с доступными панелями. Divider поддерживает accessibility adjustment.

Пример `Samples/Components P2.sputnikbook`: атомарный диапазон, дата/часовой пояс, живые logs/tasks, Data Table, runtime status, история и сравнение в Split View. Тест `notebook_macos_history_tests --p2-only` исполняет пример через worker и снимает light/dark UI.

## Shared selection и Image Annotator

В палитре дизайнера вкладка **Annotations** содержит **Image Annotator** и **Audio Annotator**. Карточка Image Annotator добавляет Image с включёнными разметкой и загрузкой изображений. У существующих Image/Image Carousel разметка по-прежнему включается через **Enable image annotations** в Object Inspector; формат проекта остаётся `kind: "image"` / `"image_carousel"` с `image_annotator: true`.

В дизайнере Data Table задаются `selection_id` (канал) и `selection_key` (имя либо ID уникальной скалярной колонки). Нажатие строки остаётся черновым выбором. Apply selection сохраняет typed key и row одним принятым снимком; Clear очищает снимок. Эти жесты не запускают код. Сортировка и фильтр не меняют ключ; Int64 не конвертируется в Double. При дублирующихся ключах/именах колонок или null key Apply недоступен.

`notebook.selection("record")` возвращает map `{version, source, key, row}` либо null после Clear. `source` — SHA-256 исходного JSON snapshot таблицы. После изменения таблицы UI предлагает повторить выбор; сохранённый снимок содержит прежний source. Один канал имеет одного владельца. Данные сохраняются в manifest и входят в frozen inputs следующего Run. In-process kernel точно инвалидирует читателей; desktop host без локального kernel консервативно помечает outputs code-ячеек устаревшими.

Image/Image Carousel и Audio Player могут читать тот же `selection_id`; `selection_asset` указывает колонку row с `asset_id` (default `asset_id`). Связь основана на SHA-256 байтов media, а не позиции строки или карусели. Image descriptor содержит поле `asset_id`; AudioTrack предоставляет `.asset_id()`. Аудиосвязь относится к готовому треку: активный stream не имеет завершённой file identity. Карусель с фильтром selection не меняет состав исходной коллекции.

Image Annotator включается у Image/Image Carousel опцией `image_annotator`. Канал принятой разметки — `annotation_id` (default `<component>_labels`). Есть точки, прямоугольники, классы, правка координат, удаление, Undo/Redo до 50 шагов и JSON export черновика. Apply сохраняет `{version, asset, channel, width, height, shapes}`: координаты принадлежат исходным пикселям, до 500 shapes и 256 KiB. Backend проверяет актуальный image hash, размеры и границы фигур. Открытый редактор удерживает свою версию картинки; новая публикация не переносит на неё черновик.

`notebook.annotations("labels")` возвращает обычный map или null, если картинка уже сменилась. Замена через UI очищает разметку отсутствующего asset. Смена image channel также требует нового Apply. Audio Annotator позднее добавлен отдельным запросом: [контракт аудиоразметки](notebook-audio-annotations.md).

Пример `Samples/Selection and Labels.sputnikbook`: ячейка 1 публикует корпус; выберите строку и Apply, откройте Annotate, сохраните метки, затем выполните ячейку 2. `make test-notebook-component-data` проверяет типы, неизменяемость, stale source rejection, bounds, Apply без исполнения, чтение через worker, Undo/Redo, reopen и native themes.

## Неиспользуемые managed media

Notebook Settings → Manage unused media показывает generated filenames внутри `images/` и `audio/`, не упомянутые в manifest или текущем коде. Перед переносом ссылки проверяются повторно. Symlinks и пользовательские имена не затрагиваются. Выбранные файлы перемещаются в `.notebook-unused/<uuid>/images|audio` с индексом `files.json`; их можно вернуть на исходные пути. Архив не освобождает место окончательно. History snapshots содержат собственные media bytes. Автоматического GC или анализа динамически построенных файловых путей нет.
