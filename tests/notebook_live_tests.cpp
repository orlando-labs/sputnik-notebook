#include "runtime/notebook_live.h"

#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>
#include <thread>
#include <limits>
#include <fstream>

namespace {

using sputnik::runtime::NotebookDisplay;
using sputnik::runtime::NotebookLiveEventKind;
using sputnik::runtime::NotebookLivePublishResult;
using sputnik::runtime::NotebookLiveScope;
using sputnik::runtime::NotebookLiveStore;

void expect(bool condition, const std::string &message) {
  if (!condition) {
    std::cerr << "notebook live test failed: " << message << '\n';
    std::exit(1);
  }
}

void test_replacement_and_immutable_snapshot() {
  auto store = std::make_shared<NotebookLiveStore>();
  const auto generation = store->begin_cell(7);
  expect(store->publish_progress(7, "loss", 1.0, 4.0, "epoch 1", false,
                                 100, generation) ==
             NotebookLivePublishResult::Accepted,
         "first progress update should be accepted");
  expect(store->publish_progress(7, "loss", 2.0, 4.0, "epoch 2", false,
                                 125, generation) ==
             NotebookLivePublishResult::Accepted,
         "same progress id should replace");
  auto figure = NotebookDisplay{"image/png", "png", "loss plot", 2, 2};
  figure.plot_scene = "{\"version\":1}";
  expect(store->publish_figure(7, "loss-plot", figure, 0, 125, generation) ==
             NotebookLivePublishResult::Accepted,
         "figure should be accepted");
  const auto snapshot = store->snapshot_cell(7);
  expect(snapshot.size() == 2U &&
             snapshot[0].kind == NotebookLiveEventKind::Progress &&
             snapshot[0].current == 2.0 && snapshot[0].elapsed_ms == 25U &&
             snapshot[1].kind == NotebookLiveEventKind::Figure,
         "snapshot should contain latest progress and figure panels");
  expect(snapshot[0].sequence < snapshot[1].sequence,
         "accepted replacements should retain monotonic sequences");
  figure.plot_scene = "{\"version\":2}";
  expect(store->publish_figure(7, "loss-plot", figure, 0, 150, generation) == NotebookLivePublishResult::Accepted,
         "scene replacement is accepted");
  expect(snapshot[1].display.plot_scene == "{\"version\":1}" &&
             store->snapshot_cell(7)[1].display.plot_scene == "{\"version\":2}",
         "live scenes are immutable copies, replaced with their image");
  figure.plot_scene.assign(4U * 1024U * 1024U + 1, 'x');
  expect(store->publish_figure(7, "too-large", figure, 0, 175, generation) == NotebookLivePublishResult::Invalid,
         "live scenes enforce their own byte limit");
}

void test_throttle_terminal_frame_and_stale_generation() {
  auto store = std::make_shared<NotebookLiveStore>();
  const auto generation = store->begin_cell(3);
  NotebookDisplay display{"image/png", "one", "", 1, 1};
  expect(store->figure_due(3, "plot", 100, 100),
         "first frame should be due");
  expect(store->publish_figure(3, "plot", display, 100, 100, generation) ==
             NotebookLivePublishResult::Accepted,
         "first frame should be accepted");
  expect(!store->figure_due(3, "plot", 100, 150),
         "recent frame should be throttled before rendering");
  expect(store->publish_figure(3, "plot", display, 100, 150, generation) ==
             NotebookLivePublishResult::Throttled,
         "publish should close the concurrent throttle race");
  expect(store->publish_figure(3, "plot", display, 0, 150, generation) ==
             NotebookLivePublishResult::Accepted,
         "zero throttle should accept terminal frame");
  const auto next_generation = store->begin_cell(3);
  expect(next_generation != generation &&
             store->publish_progress(3, "loss", 1, 2, "stale", false, 200,
                                     generation) == NotebookLivePublishResult::Closed,
         "late event from a restarted cell should be rejected");
  expect(store->publish_progress(3, "loss", 1, 2, "fresh", false, 200,
                                 next_generation) ==
             NotebookLivePublishResult::Accepted,
         "new generation should be accepted");
  std::uint64_t revision = 0;
  std::vector<sputnik::runtime::NotebookLiveEvent> snapshot;
  expect(store->snapshot_if_changed(&revision, &snapshot) && snapshot.size() == 1,
         "first revision snapshot");
  expect(!store->snapshot_if_changed(&revision, &snapshot), "unchanged store skips PNG copying");
  store->begin_cell(3);
  expect(store->snapshot_if_changed(&revision, &snapshot) && snapshot.empty(),
         "reset invalidates snapshot even without a subsequent event");
}

void test_tls_scope_and_close() {
  auto store = std::make_shared<NotebookLiveStore>();
  const auto generation = store->begin_cell(9);
  {
    NotebookLiveScope scope(store, 9, generation);
    expect(NotebookLiveScope::current() == store &&
               NotebookLiveScope::current_cell_id() == 9,
           "scope should expose the current run sink");
    expect(NotebookLiveScope::progress("batch", 1, 2, "loading") ==
               NotebookLivePublishResult::Accepted,
           "scope progress should publish");
  }
  expect(!NotebookLiveScope::current(), "scope should restore prior TLS state");
  store->close();
  expect(store->publish_progress(9, "late", 1, 1, "", true, 500,
                                 generation) == NotebookLivePublishResult::Closed &&
             store->snapshot().empty(),
         "closed store should reject and release late events");
}

void test_payload_limits() {
  NotebookLiveStore store;
  expect(store.publish_progress(1, "p", std::numeric_limits<double>::infinity(), 1, "", false) == NotebookLivePublishResult::Invalid,
         "infinite values never enter UI telemetry");
  expect(store.publish_progress(1, "p", -1, 1, "", false) == NotebookLivePublishResult::Invalid,
         "negative counts are rejected");
  for (std::size_t i = 0; i < NotebookLiveStore::kMaxEntries; ++i)
    expect(store.publish_progress(1, std::to_string(i), 0, 10, "", false) == NotebookLivePublishResult::Accepted,
           "bounded entries fit");
  expect(store.publish_progress(1, "overflow", 0, 10, "", false) == NotebookLivePublishResult::LimitExceeded,
         "new entries do not grow past the quota");
  expect(store.publish_progress(1, "0", 2, 10, "", false) == NotebookLivePublishResult::Accepted,
         "replacement remains possible at quota");
}

void test_board_point_deltas_and_rolling_window() {
  NotebookLiveStore store;
  const auto generation = store.begin_cell(21);
  std::uint64_t cursor = 0;
  NotebookLiveStore::Delta delta;
  store.append_board_chart(21, generation, "loss", {0, -1});
  expect(store.changes_since(&cursor, &delta) && delta.events.size() == 1 &&
         delta.events[0].replace_chart && delta.events[0].chart_points.size() == 1 &&
         delta.resets == std::vector<std::uint64_t>{21}, "first board sample accompanies its reset");
  store.append_board_chart(21, generation, "loss", {1, -2});
  expect(store.changes_since(&cursor, &delta) && delta.events.size() == 1 &&
         !delta.events[0].replace_chart && delta.events[0].chart_points.size() == 1 &&
         delta.events[0].chart_total_points == 2, "later samples are incremental numeric deltas");
  expect(store.snapshot().size() == 1 && store.snapshot()[0].chart_points.size() == 2,
         "whole-store snapshots include board points");
  std::vector<sputnik::runtime::NotebookLiveEvent> snapshot;
  std::uint64_t snapshot_cursor = 0;
  expect(store.snapshot_if_changed(&snapshot_cursor, &snapshot) && snapshot[0].replace_chart &&
         snapshot[0].chart_points.size() == 2, "changed-store snapshot carries complete chart history");
  for (int i = 2; i < 65536; ++i) store.append_board_chart(21, generation, "loss", {double(i), 1});
  store.changes_since(&cursor, &delta);
  store.append_board_chart(21, generation, "loss", {65536, 99});
  expect(store.changes_since(&cursor, &delta) && delta.events[0].chart_points.size() == 1 &&
         !delta.events[0].replace_chart, "rolling window sends the new sample without retransmitting history");
  for (int i = 65537; i <= 524288; ++i) store.append_board_chart(21, generation, "loss", {double(i), 2});
  const auto rolling = store.snapshot_cell(21);
  expect(rolling[0].chart_total_points == 524289 && rolling[0].chart_points.size() == 65536 &&
         rolling[0].chart_points.back()[0] == 524288, "retained-point budget does not cap total published samples");
  const auto next = store.begin_cell(21);
  store.append_board_chart(21, next, "accuracy", {1, 98});
  expect(store.changes_since(&cursor, &delta) && delta.resets.size() == 1 &&
         delta.events.size() == 1 && delta.events[0].id == "accuracy", "rerun retires channels no longer published");
  bool rejected = false;
  try { store.append_board_chart(21, generation, "loss", {0, 1}); }
  catch (const std::invalid_argument &) { rejected = true; }
  expect(rejected, "previous generation cannot publish board samples");
  rejected = false;
  try { store.append_board_chart(21, next, std::string("bad\0id", 6), {0, 1}); }
  catch (const std::invalid_argument &) { rejected = true; }
  expect(rejected, "board channel rejects embedded NUL");
}

} // namespace

int main(int argc, char **argv) {
  test_replacement_and_immutable_snapshot();
  test_throttle_terminal_frame_and_stale_generation();
  test_tls_scope_and_close();
  test_payload_limits();
  test_board_point_deltas_and_rolling_window();
  {
    NotebookLiveStore store;
    const auto generation = store.begin_cell(12);
    sputnik::runtime::NotebookChartStyle style; style.id = "loss"; style.title = "Loss \"curve\"";
    style.throttle_ms = 3600000;
    const auto chart = store.begin_chart(12, generation, style);
    std::uint64_t cursor = 0;
    NotebookLiveStore::Delta delta;
    expect(store.changes_since(&cursor, &delta) && delta.resets == std::vector<std::uint64_t>{12}, "initial delta records cell reset");
    for (int i = 0; i < 3000; ++i) store.append_chart(chart, {double(i), double(i % 11)});
    store.end_chart(chart);
    const auto result = store.finish_charts(12, generation);
    expect(result.size() == 1 && result[0].display.bytes.empty() &&
               result[0].display.mime == "application/vnd.sputnik.plot+json", "asynchronous board chart never renders PNG on producer");
    if (argc == 2) std::ofstream(argv[1]) << result[0].display.plot_scene;
    expect(result[0].display.plot_scene.find("2999") != std::string::npos &&
               result[0].display.plot_scene.find("Loss \\\"curve\\\"") != std::string::npos,
           "terminal scene includes last point and escaped metadata despite throttle");
    expect(store.changes_since(&cursor, &delta) && delta.events.size() == 1 &&
               delta.events[0].kind == NotebookLiveEventKind::Figure, "new chart is a figure-only delta");
    store.publish_progress(12, "training", 3, 10, "", false, 100, generation);
    expect(store.changes_since(&cursor, &delta) && delta.events.size() == 1 &&
               delta.events[0].kind == NotebookLiveEventKind::Progress,
           "progress-only delta contains no retained graph buffers");
    bool rejected = false;
    try { store.append_chart(chart, {3000, 1}); } catch (const std::invalid_argument &) { rejected = true; }
    expect(rejected, "ended stream rejects points");
    store.begin_cell(12);
    expect(store.changes_since(&cursor, &delta) && delta.resets.size() == 1 && delta.events.empty(),
           "rerun clears both progress and scene explicitly");
    rejected = false;
    try { store.append_chart(chart, {3000, 1}); } catch (const std::invalid_argument &) { rejected = true; }
    expect(rejected, "retired handle cannot enter next cell generation");
    NotebookLiveStore next;
    const auto nextGeneration = next.begin_cell(12);
    const auto nextChart = next.begin_chart(12, nextGeneration, style);
    expect(nextChart != chart, "handles are distinct across run stores");
    rejected = false;
    try { next.append_chart(nextChart, {std::numeric_limits<double>::infinity(), 1}); }
    catch (const std::invalid_argument &) { rejected = true; }
    expect(rejected, "nonfinite points reject before publication");
    for (int i = 0; i < 70000; ++i) next.append_chart(nextChart, {double(i), double(i % 5)});
    next.end_chart(nextChart);
    const auto rolling = next.finish_charts(12, nextGeneration);
    expect(rolling.size() == 1 && rolling[0].display.caption.find("of 70000 points") != std::string::npos &&
               rolling[0].display.plot_scene.find("69999") != std::string::npos,
           "long-running chart rolls its display window without interrupting producer");
    next.close();
    rejected = false;
    try { next.append_chart(nextChart, {1, 1}); } catch (const std::invalid_argument &) { rejected = true; }
    expect(rejected, "closed store rejects stream work");
    NotebookLiveStore tiny;
    const auto tinyGeneration = tiny.begin_cell(13);
    const auto tinyChart = tiny.begin_chart(13, tinyGeneration, style);
    tiny.append_chart(tinyChart, {1e-200, 1e-200});
    tiny.append_chart(tinyChart, {2e-200, 2e-200});
    const auto tinyResult = tiny.finish_charts(13, tinyGeneration);
    expect(tinyResult.size() == 1 &&
               tinyResult[0].display.plot_scene.find("\"bounds\":[-0.5,-0.5,0.5,0.5]") != std::string::npos,
           "near-constant auto axes remain numerically resolvable by native viewer");
  }
  std::cout << "notebook_live_tests: ok\n";
  return 0;
}
