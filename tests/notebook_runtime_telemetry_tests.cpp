#include "runtime/context.h"
#include "runtime/text.h"
#include "tools/notebook-worker/presentation.h"
#include <iostream>
#include <stdexcept>
using namespace sputnik::runtime;
using namespace sputnik::notebook::worker;
static void check(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
int main() {
  try {
    auto run = std::make_shared<RuntimeRunState>();
    RuntimeRunCancellationScope scope(run);
    auto parent = run->register_task();
    {
      RuntimeRunTaskScope activity(parent);
      auto child = run->register_task();
      const auto snapshot = run->telemetry();
      check(snapshot.tasks.size() == 2 && snapshot.tasks[1].parent == parent->id(), "runtime task parent comes from actual membership");
      run->finish_task(child->id(), "failed", "expected child error");
      child.reset();
      auto other = std::make_shared<RuntimeRunState>();
      RuntimeRunCancellationScope different(other);
      auto root = other->register_task();
      check(other->telemetry().tasks[0].parent == 0, "task parent cannot leak across run scopes");
    }
    parent.reset();
    auto snapshot = run->telemetry();
    check(snapshot.active == 0 && snapshot.total == 2 && snapshot.tasks[1].state == "failed", "terminal failure survives registration retirement");
    for (int i = 0; i < 600; ++i) { auto registration = run->register_task(); }
    snapshot = run->telemetry();
    check(snapshot.tasks.size() == 512 && snapshot.dropped > 0, "task metadata retention is bounded");
    auto out = RuntimeTextWriter::cell_stream("stdout");
    for (int i = 0; i < 3000; ++i) out->write_line(std::string(500, 'x'));
    auto events = out->events();
    std::size_t bytes = 0; for (const auto &event : events) bytes += event.text.size();
    check(bytes < 263000 && events.size() <= 2049 && events[0].stream == "truncation", "live logs keep bounded bytes/events and an explicit loss marker");
    check(out->to_string().size() <= 262144 && out->revision() == 6000, "cell text buffer is bounded and revisions survive pruning");
    auto buffer = RuntimeTextWriter::buffer(); buffer->write_str(std::string(300000, 'a'));
    check(buffer->to_string().size() == 300000, "ordinary string buffers keep their semantics");
    Presentation value; value.telemetry = snapshot; value.telemetry.cpu_percent = 32.5; value.telemetry.resident_bytes = 1000000; value.telemetry.sampled_ms = 17;
    CellPresentation cell; cell.id = 1; cell.output = events; cell.output_revision = out->revision(); value.cells.push_back(cell);
    const auto roundtrip = decode_presentation(encode_presentation(value));
    check(roundtrip.telemetry.tasks.size() == 512 && roundtrip.telemetry.cpu_percent == 32.5 && roundtrip.cells[0].output_revision == 6000, "typed telemetry and logs survive the worker protocol");
    std::cout << "Runtime telemetry passed: real task membership, parent isolation, failures, bounded retention, log truncation and binary presentation\n";
  } catch (const std::exception &error) { std::cerr << "Runtime telemetry failed: " << error.what() << '\n'; return 1; }
}
