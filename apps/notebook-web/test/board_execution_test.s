package board_execution_test
from "../backend/execution" import Execution
export main
def check(value, message): raise ValueError(message) unless value
class Catalog:
  def require_project(current, id): {core_project_id: "private-core-id"}
class Notebooks:
  attr state
  def init():
    @state = {board: "dash", component: "job", controller: "main", revision: "rev", enabled: false, running: false,
      runs: 9223372036854775807, failures: 0, skipped: 0, status: "/private/internal/worker failed", history: []}
  def call(method, params, execution: false): {services: [@state]}
def main():
  notebooks = Notebooks()
  execution = Execution(Catalog(), notebooks)
  empty = execution.service_history(null, "x", "dash", "job")
  check(empty[:history].empty? and empty[:before] == null, "empty history")
  check(empty[:service][:runs] == "9223372036854775807", "exact counters")
  check(not Json.generate(empty).contains?("/private/"), "private scheduler diagnostics")
  120.times |index|:
    notebooks.state[:history].push!({id: index + 1, started: 0.0, duration: 0.1, ok: true, value: "value", error: null})
  notebooks.state[:history][119][:value] = "x" * 5000
  first = execution.service_history(null, "x", "dash", "job")
  check(first[:history].count == 50 and first[:history][0][:id] == "120" and first[:before] == "71", "bounded newest page")
  check(first[:history][0][:value].length == 4096 and first[:history][0][:truncated], "bounded preview")
  second = execution.service_history(null, "x", "dash", "job", first[:before])
  check(second[:history][0][:id] == "70" and second[:before] == "21", "older cursor")
  last = execution.service_history(null, "x", "dash", "job", second[:before])
  check(last[:history].count == 20 and last[:before] == null, "last page")
  check(execution.service_history(null, "x", "dash", "job", "1")[:history].empty?, "expired cursor")
  notebooks.state[:history] = [{id: 1, started: 0.0, duration: 0.1, ok: false, value: null, error: "Ошибка 💫"}]
  error = execution.service_history(null, "x", "dash", "job")[:history][0]
  check(error[:error] == "Ошибка 💫" and error[:truncated] == false, "unicode error retention")
  print "PASS board execution DTOs: empty/paged history, bounded previews, Unicode, exact counters and private diagnostics"
