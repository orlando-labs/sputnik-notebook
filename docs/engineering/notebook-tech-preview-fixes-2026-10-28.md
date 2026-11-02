# Исправления пяти дефектов из аудита tech preview

Дата: 2026-10-28. Исходный отчёт: [аудит](notebook-tech-preview-audit-2026-10-28.md).

## Изменения

1. **Смена notebook защищена на serial worker queue.** Native handle получает UUID владельца при успешном открытии. Export, restore, import результата, применение inputs, обычные команды и изменения режима worker проверяют UUID до обращения к handle. UUID готовится до enqueue открытия, а публикуется вместе с успешно открытым документом. Неудачный open сохраняет прежнего владельца и его черновики. Проверка в UI completion сохранена как дополнительная защита от запоздавшей публикации.

2. **Неоднозначный ответ сохраняет исходную команду.** HTTP 5xx, таймауты и HTTP 401 не удаляют pending ticket. Reconnect восстанавливает результат через receipt с исходным CommandId. Пока команда не разрешена, новый Run/Apply inputs запрещён. Определённый validation rejection, например 422, снимает pending без разрыва соединения. Правило применяется также к recovery paths, board actions и service commands.

3. **Внешние процессы завершаются вместе с worker.** Host запускает worker в отдельной POSIX session. В ней остаются и собственные process groups, создаваемые `system.command`. При Force Stop host приостанавливает evaluator и группы команд, повторно обнаруживает потомков и завершает всю сессию. `waitid(...WNOWAIT)` сохраняет владение session leader до окончания cleanup; terminal lifecycle подтверждается после исчезновения исполняющихся членов сессии и `waitpid`. Те же правила действуют при аварии worker и уничтожении host handle. При потере владения дочерним PID сигнал не отправляется. Для macOS используется libproc, для Linux — `/proc`.

   Это управление обычными дочерними процессами, включая scoped `capture()` и вложенный shell. Произвольный доверенный native-код по-прежнему имеет доступ приложения; намеренное создание независимой OS session/daemon не является поддерживаемой гарантией изоляции.

4. **Исход последней action определяется без привязки к artifact.** Remote controller отдельно выбирает последнюю invocation каждого board/component. Terminal run без presentation всё равно загружает status/error и заменяет прежний success. Во время нового запуска прежнее значение помечается stale; reset epochs очищают результаты соответствующих invocation.

5. **Подготовка Periodic Work не меняет опубликованное состояние до commit.** `Services.dispatch` готовит глубокую копию state. Только успешная транзакция сохраняет Run и публикует `running=true`. Обработчик ошибки также работает с копией; если запись ошибки временно недоступна, общий state сохраняет согласованную версию для следующей попытки. После SQLITE_BUSY сервис доступен для нового Start без перезапуска agent.

## Регрессионные проверки

- `tests/notebook_macos_model_tests.swift`: детерминированная очередь old export → новый документ, failed open, повторное открытие того же пути; 5xx при Run/actions/services/project inputs/cell inputs; повторный 503 на receipt lookup; запрет второй команды до восстановления; определённый 422; success → interrupted/force-stopped/failed без presentation.
- `tests/notebook_worker_tests.cpp`: Force Stop, авария worker и destruction с shell/sleep в отдельной process group; проверка отсутствия отложенного побочного эффекта; проверка утраты PID ownership.
- `tests/notebook_remote_tests.py`: реальные Force Stop/worker crash с внешней командой; блокировка временной SQLite дольше busy timeout, отсутствие phantom Run и успешный новый Start.

## Валидация

На macOS пройдены core API в VM/full-native, readiness, worker/worker-host, cancellation/run tasks, native CLI, **48 remote integration tests**, расширенный Swift model suite и реальные remote UI/work integrations. Собран `.app`, пройдены AppKit/SwiftUI smoke, Dock icon и theme switching.

Логи и fingerprint исходников: [evidence](../evidence/2026-10-28/tech-preview-fixes/README.md). Отдельный Linux-прогон этого изменения не выполнялся. Production remote не обновлялся.

Подпись/распространение, матрица macOS и ограничение remote storage из исходного аудита — отдельные условия выпуска, за пределами этих пяти исправлений.
