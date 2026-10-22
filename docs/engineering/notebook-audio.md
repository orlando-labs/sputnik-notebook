# AudioTrack и Audio Player

Первая реализация использует AVFoundation/AudioToolbox macOS. FFmpeg и внешние codec executables не требуются. Модуль `audio` поставляется в пакете `sputnik-lang/packages/notebook_ui`; работа с данными не создаёт UI и не открывает аудиоустройство.

```sputnik
from audio import AudioTrack
from notebook.ui import AudioPlayer

track = AudioTrack.from_file("speech.wav")
notebook.player(track, id: "speech")
notebook.show(AudioPlayer.for(track, position: 0.25, volume: 0.5), id: "preview")
```

`from_data(binary, format: "mp3")` принимает точные байты `Str`, `Bytes` или byte buffer. `format` — расширение контейнера. `wav` обозначает целый RIFF/WAVE файл. Сырые PCM задаются отдельно:

```sputnik
track = AudioTrack.from_pcm(data, sample_format: :s16le,
  sample_rate: 48000, layout: :stereo, interleaved: true)
```

Поддержаны s16le/f32le, 8–192 kHz, mono/stereo. Вместо `layout` можно задать `channels: 1/2`. Planar-ввод нормализуется в interleaved. Отклоняются неполные frames, неизвестный sample format и NaN/Inf. При преобразовании в s16le значения вне [-1,1] отклоняются. `to_pcm(sample_format: ...)` возвращает AudioTrack; `.data()` — PCM bytes; `.to_wav(sample_format: ...)` — байты RIFF/WAVE. Системный декодер определяет доступность encoded codec; неизвестный формат даёт ошибку.

Параметры `AudioPlayer.for` и короткой формы: `position`, `volume`, `looped`, `autoplay`, `show_waveform`. Значение `looped` используется потому, что `loop` — ключевое слово языка. По умолчанию autoplay выключен. Публикация возвращает null и не подменяет скалярный результат ячейки.

Audio Player доступен в палитре Display, на листе и в pre/post UI ячейки. `audio_id` выбирает канал публикации. Show waveform в дизайнере имеет приоритет над исходным descriptor. Изменение waveform не сбрасывает позицию или pause. В меню доступны исходный файл, WAV и копирование метаданных; у PCM stream экспортируется накопленный WAV.

## Streaming

```sputnik
stream = AudioTrack.stream(sample_format: :f32le, sample_rate: 48000, channels: 2)
notebook.player(stream, id: "generated")
stream.append(first_chunk)
stream.append(next_chunk)
stream.finish()
# stream.reset() начинает новый playback epoch с тем же объектом источника.
```

Открытие stream требует активного запуска ноутбука. Append передаёт новые interleaved PCM frames; повторный show не нужен. Worker отправляет sequence/revision, frame offset и дельту bytes. Reconnect и сохранённый результат содержат полный retained snapshot. Повторная доставка не дублирует звук. Finish запрещает append до reset; новый Run/Stop закрывает producer context. При завершении Run незакрытые потоки получают terminal finish после drain дочерних задач.

Буферы ограничены: 16 MiB PCM на источник, 64 MiB на Run, восемь источников и 64 плеера. Заполнение даёт явную ошибку append, не удаляет непрослушанные frames. Это ограниченный накопительный поток, а не бесконечная архивная запись. Компонент показывает buffering при underrun; retained данные позволяют seek и повторное прослушивание. Аудиочасы не зависят от частоты перерисовки waveform.

## Hard ID

```sputnik
player = notebook.component("preview_player", board: "audio_board")
player.seek(0.5)
player.set_volume(0.4)
player.play()
player.pause()
player.stop()
# Если выбранный channel связан с открытым PCM stream:
player.append(chunk)
player.finish()
```

Hard ID принадлежит авторскому компоненту. `id` в show/player принадлежит выходному каналу; token — внутренней runtime identity источника. При неоднозначном hard ID требуется `board`. Для cell UI scope имеет вид `cell_<cell ID>`. Рекомендуется явно выбирать `audio_id` в инспекторе компонента. Handle проверяется по текущему manifest; удалённый/перенастроенный компонент даёт ошибку.

Play, seek и volume имеют независимые монотонные revisions: coalescing сохраняет итоговое состояние и порядок разных команд. Лист и доска используют один controller одного канала. В документе по умолчанию играет один источник. Playback и экспорт выполняет клиент, включая результаты remote worker.

## Транспорт и проверки

Static output: MIME `application/vnd.sputnik.audio`, бинарный SPKA1 envelope с настройками и точным содержимым файла. Live PCM и control state имеют отдельные типизированные поля presentation v15, private protocol v17. Чтение сохранённых presentations v14/v13/v12/v11 сохранено. Старый worker требует обновления, а не получает audio bytes как PNG.

Примеры: `Samples/Audio.sputnikbook` и `Samples/Audio Streaming.sputnikbook`. Файлы разрешаются относительно `.sputnikbook`; чтение пользовательского файла требует обычного `fs.read` grant worker. Примеры не выдают разрешения самостоятельно.

Проверки: `make test-notebook-audio`, `make test-notebook-audio-ui`. Нативная проверка использует реальный системный audio output и требует доступа к нему у процесса теста.

## Audio Input / Recorder

В палитре Controls добавлен Audio Input / Recorder. В дизайнере задаются канал `audio_id` и разрешённость записи. Choose/drop или Record создают локальный draft с предпрослушиванием. Apply сохраняет новый immutable файл в `audio/` внутри `.sputnikbook`; Clear также требует Apply. Discard не меняет принятый вход.

```sputnik
from audio import AudioTrack
track = AudioTrack.from_input("voice")
notebook.player(track)
```

Run получает snapshot bytes принятого входа. Внешний путь не передаётся в код; `fs.read` для чтения этого входа не нужен. Замена/Clear инвалидирует зависимости читавших ячеек, исполнение остаётся явным. Старые frozen snapshots сохраняют собственные bytes. Symlink/traversal отклоняются на чтении managed member. Один вход ограничен 16 MiB, все принятые аудиовходы листа — 64 MiB.

Recorder использует выбранное системное input device, 16-bit WAV, ограничение 30 секунд, peak/RMS dBFS и clipping. Микрофон открывается только нажатием Record. Stop превращает запись в draft; Accept выполняется кнопкой Apply после предпрослушивания. Отказ доступа, отключение устройства и ошибка записи показываются в компоненте. Закрытие компонента отменяет незавершённый запрос доступа и удаляет временную запись. Реальное получение записи требует разрешения macOS; автоматические проверки его не запрашивают.

Managed assets входят в обычную передачу файлов remote revision. Импорт/запись — операции клиента, аудиоустройство сервера не используется. Remote core по-прежнему ограничивает dependency bundles и project inputs: примеры с зависимостью notebook_ui проверены локально, их полная remote-совместимость не заявлена. Запись и Apply отключены во время активного Run. После Replace/Clear старые generated media можно просмотреть в Notebook Settings → Manage unused media и перенести в восстанавливаемый архив.

Пример: `Samples/Audio Input.sputnikbook` содержит принятый WAV, компонент импорта/записи, кнопку Run и выходной плеер. `build/notebook_macos_audio_tests --input-only --worker <path>` проверяет Apply/Clear и чтение через настоящий worker без filesystem grant.

Готовый AudioTrack предоставляет `.asset_id()` — SHA-256 encoded файла; для PCM — экспортируемого WAV. Это identity для связи с Data Table через shared selection. Player channel и hard ID компонента остаются отдельными понятиями.

Дополнительная системная проверка: MP3 декодирован в f32 PCM, 23,040 frames, 44,100 Hz mono. Нативный тест подтвердил воспроизведение файла/PCM и приём streaming до завершения Run; проверка реального микрофонного take не проводилась.
