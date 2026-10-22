# Реализация оставшегося набора компонентов

20 октября 2026. Пользователь разрешил поэтапную реализацию. Audio Compare / Collection исключён. Audio Annotator / Transcript и Spectrogram были исключены из первого набора, затем возвращены отдельным запросом пользователя; текущая реализация описана ниже.

Каждый этап включает рабочий пример, проверки runtime/worker и общий UI листа/доски. Авторские настройки отделены от runtime state. Нужные изменения в языке выполняются в sibling sputnik-lang, без отмены имеющихся изменений.

1. **AudioTrack и Audio Player — базовый этап проверен.** Файл, бинарная Str с явным форматом, PCM; системное воспроизведение, AudioPlayer.for, notebook.show и notebook.player, начальная позиция, меню экспорта, Show waveform в дизайнере, pre/post-компоненты.
2. **Живой audio channel — проверен.** Begin/append/finish/reset, bounded buffers, backpressure, hard-ID commands, cancellation/reconnect и проверка настоящего playback.
3. **Audio Input / Recorder — импорт и Apply/Clear проверены.** Managed assets, импорт/запись, draft/Apply, чтение AudioTrack локально. Передача файлов использует remote revisions; полная работа примеров с notebook_ui ограничена существующим запретом dependency bundles в remote core.
4. **Run History, Experiment Compare и Runtime Status — реализованы и проверены локально.** Снимки параметров/источников/outputs, retention, восстановление и сведения о соединении.
5. **Остальной P2 — реализован локальный набор.** Range/Date-time Input, Image Annotator, live logs, shared selection, Task Monitor, CPU/RAM worker и Split View. GPU явно unavailable. Неиспользуемые generated media можно просмотреть и перенести в восстанавливаемый архив.

Event Work остаётся отложенным согласно предыдущему roadmap. FFmpeg не используется. Исключённые аудиокомпоненты не возвращаются под видом режимов плеера.

Базовый этап: C++ package/worker roundtrip и нативный playback/seek/pause с waveform toggle прошли. Потоковый транспорт, настоящая генерация/playback до завершения Run и hard-ID state прошли интеграционную проверку. Импорт/Apply/Clear и Recorder реализованы; microphone permission запрашивается только кнопкой Record. Рабочий API и ограничения: [notebook-audio](../engineering/notebook-audio.md).

Проверены live logs, настоящее дерево runtime tasks и resident RAM до завершения Run, bounded logs/tasks, старые presentation schemas и история после Stop. Range/Date backend прошёл проверки атомарности, Int64 > 2^53 и календарных дат. Split View и объединённый пример проходят нативную проверку. Shared selection и Image Annotator прошли C++ и нативный тест через worker: source/asset identity, Apply без Run, инвалидация, Undo/Redo и чтение следующим Run. Проверен восстанавливаемый архив media с исключением ссылок и symlinks. Настоящий microphone take не проверялся. После сброса лимита разрешений прошли все 25 HTTP-тестов remote core, loopback-тест дочерних задач, системное MP3 → PCM (44.1 kHz mono) и нативное воспроизведение/streaming. Исправлены два блокировавших сборку native helper дефекта генератора/файлового адаптера; отдельная native-регрессия записи Str/Bytes и method_missing прошла.

Контракты и ограничения: [P2 components](../engineering/notebook-p2-components.md).

Итоговый macOS app bundle собран и проверен `codesign --verify --deep --strict`. Smoke-тест упакованного приложения с isolated worker проверил рендеринг, Dock icon и переключение тем. Встроенный worker валидировал оба новых демоноутбука. Во время параллельных изменений общего runtime финальная Swift-линковка использовала зафиксированные копии двух статических библиотек.

По новому запросу пользователя Audio Annotator и спектрограмма возвращены в scope отдельным компонентом: временные/частотные области, классы и типизированные вторичные атрибуты, транскрипт, FFT Accelerate и plasma. [Контракт](../engineering/notebook-audio-annotations.md). Audio Compare/Collection остаётся исключённым.
