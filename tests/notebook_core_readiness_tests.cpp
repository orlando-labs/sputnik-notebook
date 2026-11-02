#include "tools/isputnik/session.h"
#include <cstdlib>
#include <iostream>

static void check(bool value, const char *message) {
  if (!value) { std::cerr << "core readiness: " << message << '\n'; std::exit(1); }
}
int main() {
  Session session;
  check(!has_pending_runtime_events(session), "unopened world is idle");
  Cell cell;
  cell.id = 1;
  cell.source = "x = 1\nKernel.watch(x)\nx = 2\nx\n";
  session.cells.push_back(cell);
  evaluate_from(&session, 0, true, false, false);
  check(session.cells[0].ok, "watch fixture executes");
  const bool pending = has_pending_runtime_events(session);
  check(has_pending_runtime_events(session) == pending, "readiness does not acknowledge events");
  pump_runtime_events_detailed(&session, false, {});
  check(!has_pending_runtime_events(session), "drained world is idle");
  session.activity_notifier().notify_runtime();
  check(session.activity_waiter().wait(std::chrono::milliseconds(0)).runtime_ready,
        "stale wakeup is still observable");
  check(!has_pending_runtime_events(session), "wakeups are not executable work");
  std::cout << "notebook_core_readiness_tests: ok\n";
}
