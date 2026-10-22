#include "tools/notebook-worker/presentation.h"
#include "runtime/audio.h"
#include <algorithm>
#include <charconv>
#include <cmath>
#include <cstring>
#include <iterator>
#include <limits>
#include <set>
#include <type_traits>

namespace sputnik::notebook::worker {
namespace {
constexpr const char *schema = "sputnik.notebook.presentation.v15";
constexpr const char *media_schema = "sputnik.notebook.presentation.v14";
constexpr const char *audio_previous_schema = "sputnik.notebook.presentation.v13";
constexpr const char *execution_schema = "sputnik.notebook.presentation.v12";
constexpr const char *previous_schema = "sputnik.notebook.presentation.v11";
constexpr std::size_t max_items = 65536;
constexpr std::size_t max_total_items = 800000;
struct Writer {
  std::string bytes;
  std::size_t total_items = 0;
  void space(std::size_t count) {
    if (count > kMaxPresentationBytes - bytes.size())
      throw ProtocolError("worker presentation exceeds 128 MiB limit");
  }
  template<class T> void number(T value) {
    if constexpr (std::numeric_limits<T>::is_signed)
      if (value < 0) throw ProtocolError("negative presentation integer");
    space(8);
    const auto n = static_cast<std::uint64_t>(value);
    for (unsigned i = 8; i > 0; --i) bytes.push_back(static_cast<char>(n >> ((i - 1) * 8)));
  }
  void str(const std::string &value) {
    number(value.size()); space(value.size()); bytes += value;
  }
  void real(double value) {
    if (!std::isfinite(value) || value < 0) throw ProtocolError("invalid progress number");
    std::uint64_t bits; std::memcpy(&bits, &value, sizeof(bits)); number(bits);
  }
  void coordinate(double value) {
    if (!std::isfinite(value) || std::abs(value) >= 1e100)
      throw ProtocolError("invalid chart coordinate");
    std::uint64_t bits; std::memcpy(&bits, &value, sizeof(bits)); number(bits);
  }
  template<class T, class F> void items(const std::vector<T> &values, F visit) {
    if (values.size() > max_items || values.size() > max_total_items - total_items)
      throw ProtocolError("too many presentation items");
    total_items += values.size(); number(values.size());
    for (const auto &value : values) visit(*this, value);
  }
};
struct Reader {
  const std::string &bytes;
  std::size_t offset = 0, total_items = 0;
  template<class T> void number(T &value) {
    if (bytes.size() - offset < 8) throw ProtocolError("truncated presentation integer");
    std::uint64_t n = 0;
    for (unsigned i = 0; i < 8; ++i) n = (n << 8) | static_cast<unsigned char>(bytes[offset++]);
    if (n > static_cast<std::uint64_t>(std::numeric_limits<T>::max()))
      throw ProtocolError("invalid presentation integer");
    value = static_cast<T>(n);
  }
  void str(std::string &value) {
    std::uint64_t size; number(size);
    if (size > bytes.size() - offset) throw ProtocolError("truncated presentation string");
    value.assign(bytes, offset, static_cast<std::size_t>(size)); offset += size;
  }
  void real(double &value) {
    std::uint64_t bits; number(bits); std::memcpy(&value, &bits, sizeof(bits));
    if (!std::isfinite(value) || value < 0) throw ProtocolError("invalid progress number");
  }
  void coordinate(double &value) {
    std::uint64_t bits; number(bits); std::memcpy(&value, &bits, sizeof(bits));
    if (!std::isfinite(value) || std::abs(value) >= 1e100)
      throw ProtocolError("invalid chart coordinate");
  }
  template<class T, class F> void items(std::vector<T> &values, F visit) {
    std::uint64_t count; number(count);
    if (count > max_items || count > max_total_items - total_items ||
        count > (bytes.size() - offset) / 8)
      throw ProtocolError("invalid presentation item count");
    total_items += count;
    // Decode each item before growing the result; untrusted lengths never
    // become an unchecked reserve/allocation.
    for (std::uint64_t i = 0; i < count; ++i) {
      T value; visit(*this, value); values.push_back(std::move(value));
    }
  }
};
template<class A, class T> void text_event(A &a, T &v) {
  a.str(v.stream); a.str(v.text); a.number(v.order);
  a.number(v.source.present); a.number(v.source.code_id); a.number(v.source.pc);
  a.str(v.source.file); a.number(v.source.line); a.number(v.source.column);
}
template<class A, class T> void local(A &a, T &v) {
  a.str(v.name); a.str(v.role); a.str(v.binding_kind); a.str(v.value); a.str(v.text_value);
  a.number(v.initialized); a.number(v.watched); a.number(v.watch_cell_id); a.number(v.watch_revision);
}
template<class A, class T> void range(A &a, T &v) {
  a.number(v.start_line); a.number(v.start_column); a.number(v.end_line);
  a.number(v.end_column); a.number(v.whole_line);
}
template<class A, class T> void display(A &a, T &v) {
  a.str(v.mime); a.str(v.caption); a.number(v.width); a.number(v.height); a.str(v.bytes);
  a.str(v.plot_scene);
  a.str(v.id);
  if (v.id.size() > 256 || v.id.find('\0') != std::string::npos || v.caption.size() > 65536)
    throw ProtocolError("invalid notebook display identity/caption");
  if (v.mime == runtime::kAudioMime) {
    if (v.width || v.height || !v.plot_scene.empty()) throw ProtocolError("invalid audio display geometry");
    try { (void)runtime::audio_decode(v.bytes); }
    catch (const std::exception &e) { throw ProtocolError(e.what()); }
    return;
  }
  if (v.mime == "application/vnd.sputnik.table+json") {
    if (v.width || v.height || !v.plot_scene.empty() || v.bytes.empty() || v.bytes.size() > 1024 * 1024)
      throw ProtocolError("invalid notebook table display");
    return;
  }
  if ((v.mime != "image/png" && v.mime != "image/jpeg" && v.mime != "application/vnd.sputnik.plot+json") || !v.width || !v.height || v.width > 8192 || v.height > 8192 ||
      static_cast<std::uint64_t>(v.width) * v.height > 16000000 ||
      v.bytes.size() > 16U * 1024U * 1024U || v.plot_scene.size() > 4U * 1024U * 1024U)
    throw ProtocolError("invalid notebook display metadata");
  if (v.mime == "application/vnd.sputnik.plot+json") {
    if (!v.bytes.empty() || v.plot_scene.empty()) throw ProtocolError("invalid scene-only notebook display");
    return;
  }
  try { runtime::notebook_validate_image(v); }
  catch (const std::exception &e) { throw ProtocolError(e.what()); }
}
template<class A, class T> void chart(A &a, T &v) {
  if constexpr (std::is_same_v<A, Reader>) v.kind = runtime::NotebookLiveEventKind::ChartPoints;
  a.str(v.id); a.number(v.chart_total_points); a.number(v.replace_chart);
  if (v.id.empty() || v.id.size() > 256 || v.id.find('\0') != std::string::npos ||
      (!std::is_same_v<A, Reader> && v.kind != runtime::NotebookLiveEventKind::ChartPoints))
    throw ProtocolError("invalid notebook chart snapshot");
  a.items(v.chart_points, [](auto &a, auto &point) {
    a.coordinate(point[0]); a.coordinate(point[1]);
  });
  if (v.chart_total_points < v.chart_points.size())
    throw ProtocolError("chart total is smaller than retained point count");
}
template<class A, class T> void cell(A &a, T &v) {
  a.number(v.id); a.number(v.source_revision); a.number(v.dirty); a.number(v.ok);
  a.str(v.result); a.str(v.error); a.number(v.watch_epoch); a.number(v.watch_event_count);
  a.str(v.result_format.pretty); a.number(v.result_format.is_container);
  a.number(v.result_format.truncated); a.number(v.result_format.pretty_truncated);
  a.str(v.result_format.table_json);
  if (v.result_format.table_json.size() > 1024 * 1024) throw ProtocolError("oversized table snapshot");
  if (v.result.size() > 65536 || v.result_format.pretty.size() > 65536)
    throw ProtocolError("oversized notebook result preview");
  a.items(v.locals, [](auto &a, auto &v) { local(a, v); });
  a.items(v.output, [](auto &a, auto &v) { text_event(a, v); });
  a.items(v.displays, [](auto &a, auto &v) { display(a, v); });
  a.number(v.displays_updated); a.number(v.progress_updated);
  if (!v.displays_updated && !v.displays.empty()) throw ProtocolError("unchanged figure delta carries data");
  std::set<std::string> progress_ids;
  a.items(v.progress, [&](auto &a, auto &p) {
    a.str(p.id); a.real(p.current); a.real(p.total); a.str(p.description);
    a.number(p.done); a.number(p.elapsed_ms);
    if (p.id.empty() || p.id.size() > 4096 || p.description.size() > 65536 ||
        !progress_ids.insert(p.id).second) throw ProtocolError("invalid progress item");
  });
  if (!v.progress_updated && !v.progress.empty()) throw ProtocolError("unchanged progress delta carries data");
  a.number(v.charts_updated); a.number(v.charts_reset);
  std::set<std::string> chart_ids;
  a.items(v.charts, [&](auto &a, auto &v) {
    chart(a, v);
    if (!chart_ids.insert(v.id).second) throw ProtocolError("duplicate chart channel");
  });
  if (!v.charts_updated && (!v.charts.empty() || v.charts_reset))
    throw ProtocolError("unchanged chart delta carries data or reset");
  a.number(v.images_updated);
  std::set<std::string> image_ids;
  a.items(v.images, [&](auto &a, auto &series) {
    if constexpr (std::is_same_v<A, Reader>) series.kind = runtime::NotebookLiveEventKind::Images;
    a.str(series.id); a.str(series.caption);
    if (series.kind != runtime::NotebookLiveEventKind::Images || series.id.empty() ||
        series.id.size() > 256 || series.id.find('\0') != std::string::npos || series.caption.size() > 65536 ||
        !image_ids.insert(series.id).second) throw ProtocolError("invalid image channel");
    a.items(series.images, [](auto &a, auto &image) {
      display(a, image);
      if ((image.mime != "image/png" && image.mime != "image/jpeg") || !image.plot_scene.empty())
        throw ProtocolError("image channel requires raster images");
    });
    if (series.images.size() > 64) throw ProtocolError("image series exceeds 64 images");
  });
  if (!v.images_updated && !v.images.empty()) throw ProtocolError("unchanged image delta carries data");
  a.items(v.error_ranges, [](auto &a, auto &v) { range(a, v); });
  a.items(v.errors, [](auto &a, auto &v) {
    a.str(v.message); a.number(v.has_range); range(a, v.range);
  });
  if (!v.id || v.displays.size() > 64 || v.progress.size() > 128 || v.charts.size() > 64 || v.images.size() > 128) throw ProtocolError("invalid notebook cell presentation");
  std::size_t display_bytes = 0;
  for (const auto &display : v.displays) display_bytes += display.storage_bytes();
  for (const auto &series : v.images) for (const auto &image : series.images) display_bytes += image.storage_bytes();
  if (display_bytes > 64U * 1024U * 1024U) throw ProtocolError("oversized notebook figure");
}
template<class A, class T> void presentation(A &a, T &v, unsigned version = 15) {
  a.number(v.cancelled); a.str(v.status); a.str(v.environment_error); a.number(v.environment_stale);
  a.items(v.environment_output, [](auto &a, auto &v) { text_event(a, v); });
  std::set<std::uint64_t> failure_ids;
  a.items(v.unobserved_task_failures, [&](auto &a, auto &v) {
    a.number(v.task_id); a.str(v.error_name); a.str(v.message);
    auto &s = v.spawn_source;
    a.number(s.present); a.number(s.code_id); a.number(s.pc);
    a.str(s.file); a.number(s.line); a.number(s.column);
    if (!v.task_id || v.error_name.empty() || !failure_ids.insert(v.task_id).second)
      throw ProtocolError("invalid notebook task failure");
  });
  a.items(v.cells, [](auto &a, auto &v) { cell(a, v); });
  if (version >= 12) a.number(v.executing_cell);
  if (version >= 13) {
    for (auto &entry : v.cells) {
      bool timed = entry.elapsed_ms.has_value();
      std::uint64_t elapsed = entry.elapsed_ms.value_or(0);
      a.number(timed); a.number(elapsed); a.number(entry.timing_running);
      if (elapsed > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()) || (entry.timing_running && !timed))
        throw ProtocolError("invalid cell elapsed time");
      if constexpr (std::is_same_v<A, Reader>) { if (timed) entry.elapsed_ms = elapsed; }
      a.number(entry.stopwatches_updated);
      std::set<std::string> ids;
      a.items(entry.stopwatches, [&](auto &a, auto &timer) {
        a.str(timer.id); a.number(timer.elapsed_ms); a.number(timer.done);
        if (timer.elapsed_ms > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()))
          throw ProtocolError("invalid stopwatch elapsed time");
        if constexpr (std::is_same_v<A, Reader>) timer.kind = runtime::NotebookLiveEventKind::Stopwatch;
        if (timer.id.empty() || timer.id.size() > 256 || timer.id.find('\0') != std::string::npos || !ids.insert(timer.id).second)
          throw ProtocolError("invalid stopwatch channel");
      });
      if (entry.stopwatches.size() > 128 || (!entry.stopwatches_updated && !entry.stopwatches.empty()))
        throw ProtocolError("invalid stopwatch delta");
    }
  }
  if (v.cells.size() > 4096) throw ProtocolError("too many notebook cells in presentation");
  std::set<CellId> ids;
  if (version >= 14) for (auto &entry : v.cells) {
    a.number(entry.audio_updated); a.number(entry.audio_reset);
    std::set<std::string> ids;
    a.items(entry.audio, [&](auto &a, auto &event) {
      if constexpr (std::is_same_v<A, Reader>) event.kind = runtime::NotebookLiveEventKind::Audio;
      a.str(event.id); a.str(event.caption);
      auto &e = event.audio;
      a.number(e.token); a.number(e.revision); a.number(e.offset); a.number(e.frames);
      a.number(e.rate); a.number(e.channels); a.str(e.sample_format); a.str(e.bytes);
      a.number(e.replace); a.number(e.finished);
      a.real(e.player.position); a.real(e.player.volume);
      a.number(e.player.waveform); a.number(e.player.loop); a.number(e.player.autoplay);
      if (event.id.empty() || event.id.size() > 256 || event.id.find('\0') != std::string::npos ||
          event.caption.size() > 65536 || !ids.insert(event.id).second || event.kind != runtime::NotebookLiveEventKind::Audio)
        throw ProtocolError("invalid audio stream channel");
      try { runtime::audio_validate_event(e); } catch (const std::exception &error) { throw ProtocolError(error.what()); }
    });
    a.number(entry.audio_controls_updated);
    std::set<std::string> control_ids;
    a.items(entry.audio_controls, [&](auto &a, auto &event) {
      if constexpr (std::is_same_v<A, Reader>) event.kind = runtime::NotebookLiveEventKind::AudioControl;
      a.str(event.id); auto &c = event.audio_control;
      a.number(c.cell); a.str(c.channel); a.number(c.playback_revision); a.number(c.seek_revision); a.number(c.volume_revision);
      a.number(c.playback); a.real(c.position); a.real(c.volume);
      if (event.id.empty() || event.id.size() > 4096 || !control_ids.insert(event.id).second || event.kind != runtime::NotebookLiveEventKind::AudioControl)
        throw ProtocolError("invalid audio control identity");
      try { runtime::audio_validate_control(c); } catch (const std::exception &error) { throw ProtocolError(error.what()); }
    });
    if (entry.audio_controls.size() > 128 || (!entry.audio_controls_updated && !entry.audio_controls.empty()))
      throw ProtocolError("invalid audio control delta");
    if (entry.audio.size() > 64 || (!entry.audio_updated && (!entry.audio.empty() || entry.audio_reset)))
      throw ProtocolError("invalid audio stream delta");
  }
  if (version >= 15) {
    for (auto &entry : v.cells) {
      a.number(entry.output_updated); a.number(entry.output_revision);
      if (!entry.output_updated && !entry.output.empty()) throw ProtocolError("unchanged log snapshot carries data");
      std::size_t bytes = 0; for (const auto &event : entry.output) bytes += event.text.size();
      if (bytes > 1024U * 1024U || entry.output.size() > 8192) throw ProtocolError("log snapshot exceeds limits");
    }
    a.number(v.telemetry_updated);
    auto &t = v.telemetry;
    a.number(t.revision); a.number(t.dropped); a.number(t.active); a.number(t.total); a.number(t.sampled_ms);
    bool cpu = t.cpu_percent.has_value(), memory = t.resident_bytes.has_value();
    double percent = t.cpu_percent.value_or(0); std::uint64_t resident = t.resident_bytes.value_or(0);
    a.number(cpu); a.real(percent); a.number(memory); a.number(resident);
    if constexpr (std::is_same_v<A, Reader>) { if (cpu) t.cpu_percent = percent; if (memory) t.resident_bytes = resident; }
    std::set<std::uint64_t> ids;
    a.items(t.tasks, [&](auto &a, auto &task) {
      a.number(task.id); a.number(task.parent); a.number(task.cell); a.number(task.elapsed_ms);
      a.str(task.state); a.str(task.error); a.str(task.file); a.number(task.line);
      if (!task.id || task.parent == task.id || !ids.insert(task.id).second || task.file.size() > 1024 || task.error.size() > 1024 ||
          (task.state != "queued" && task.state != "active" && task.state != "succeeded" && task.state != "failed" && task.state != "cancelled"))
        throw ProtocolError("invalid runtime task snapshot");
    });
    if (t.tasks.size() > 512 || t.active > t.total || (!v.telemetry_updated && (!t.tasks.empty() || cpu || memory)))
      throw ProtocolError("invalid runtime telemetry snapshot");
  }
  std::size_t chart_points = 0;
  for (const auto &entry : v.cells)
    {
      if (!ids.insert(entry.id).second) throw ProtocolError("duplicate presentation cell");
      for (const auto &chart : entry.charts) {
        chart_points += chart.chart_points.size();
        if (chart_points > 524288) throw ProtocolError("presentation chart point budget exceeded");
      }
    }
}
std::size_t size_field(const std::string &text) {
  std::size_t value = 0;
  const auto parsed = std::from_chars(text.data(), text.data() + text.size(), value);
  if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size())
    throw ProtocolError("invalid presentation size/offset");
  return value;
}
}

void merge_live_presentation(Presentation &target, Presentation update) {
  target.executing_cell = update.executing_cell;
  if (update.telemetry_updated) { target.telemetry = std::move(update.telemetry); target.telemetry_updated = true; }
  for (auto &value : update.cells) {
    auto found = std::find_if(target.cells.begin(), target.cells.end(), [&](const auto &c) { return c.id == value.id; });
    if (found == target.cells.end()) target.cells.push_back(std::move(value));
    else {
      if (value.source_revision != found->source_revision) { *found = std::move(value); continue; }
      if (value.output_updated) { found->output = std::move(value.output); found->output_updated = true; found->output_revision = value.output_revision; }
      if (value.displays_updated) { found->displays = std::move(value.displays); found->displays_updated = true; }
      if (value.progress_updated) { found->progress = std::move(value.progress); found->progress_updated = true; }
      if (value.images_updated) { found->images = std::move(value.images); found->images_updated = true; }
      if (value.audio_controls_updated) { found->audio_controls = std::move(value.audio_controls); found->audio_controls_updated = true; }
      if (value.audio_updated) {
        if (value.audio_reset) { found->audio.clear(); found->audio_reset = true; }
        for (auto &stream : value.audio) {
          auto old = std::find_if(found->audio.begin(), found->audio.end(), [&](const auto &e) { return e.id == stream.id; });
          if (old == found->audio.end()) {
            // A host's pending batch is drained between polls. Its initial
            // snapshot may already belong to the UI, so retain the delta's
            // offset rather than pretending this is a complete stream.
            found->audio.push_back(std::move(stream));
          } else {
            try { runtime::audio_merge_event(old->audio, stream.audio); }
            catch (const std::exception &error) { throw ProtocolError(error.what()); }
            old->caption = std::move(stream.caption);
          }
        }
        found->audio_updated = true;
      }
      if (value.elapsed_ms) { found->elapsed_ms = value.elapsed_ms; found->timing_running = value.timing_running; }
      if (value.stopwatches_updated) { found->stopwatches = std::move(value.stopwatches); found->stopwatches_updated = true; }
      if (value.charts_updated) {
        if (value.charts_reset || value.charts.empty()) found->charts.clear();
        found->charts_reset = found->charts_reset || value.charts_reset || value.charts.empty();
        for (auto &update : value.charts) {
          auto chart = std::find_if(found->charts.begin(), found->charts.end(), [&](const auto &old) { return old.id == update.id; });
          if (chart == found->charts.end()) {
            found->charts.push_back(std::move(update));
          } else if (update.replace_chart) {
            *chart = std::move(update);
          } else {
            chart->chart_points.insert(chart->chart_points.end(), update.chart_points.begin(), update.chart_points.end());
            if (chart->chart_points.size() > 65536)
              chart->chart_points.erase(chart->chart_points.begin(), chart->chart_points.begin() + (chart->chart_points.size() - 65536));
            chart->chart_total_points = update.chart_total_points;
          }
        }
        found->charts_updated = true;
      }
    }
  }
}

Presentation presentation_from_session(const Session &session,
    const std::map<CellId, std::uint64_t> &source_revisions, bool cancelled) {
  Presentation result; result.telemetry = session.run_telemetry;
  result.cancelled = cancelled; result.status = session.status;
  result.environment_error = session.environment_error;
  result.environment_stale = session.environment_stale;
  result.environment_output = session.environment_output;
  for (const auto &cell : session.cells) {
    CellPresentation v;
    v.id = cell.id;
    const auto revision = source_revisions.find(cell.id);
    if (revision != source_revisions.end()) v.source_revision = revision->second;
    v.dirty = cell.dirty; v.ok = cell.ok; v.result = cell.result; v.error = cell.error;
    v.result_format = cell.result_format;
    v.locals = cell.locals; v.output = cell.output_events; v.displays = cell.displays;
    v.progress = cell.progress;
    v.charts = cell.charts;
    v.images = cell.images; v.audio = cell.audio; v.audio_controls = cell.audio_controls;
    v.elapsed_ms = cell.elapsed_ms; v.stopwatches = cell.stopwatches; v.stopwatches_updated = true;
    v.charts_reset = true;
    for (auto &chart : v.charts) chart.replace_chart = true;
    v.watch_epoch = cell.watch_epoch; v.watch_event_count = cell.watch_event_count;
    v.error_ranges = cell.error_ranges; v.errors = cell.errors;
    result.cells.push_back(std::move(v));
  }
  return result;
}
std::string encode_presentation(const Presentation &value) {
  Writer writer;
  writer.str(schema); presentation(writer, value);
  return std::move(writer.bytes);
}
Presentation decode_presentation(const std::string &bytes) {
  if (bytes.size() > kMaxPresentationBytes) throw ProtocolError("oversized presentation");
  Reader reader{bytes};
  std::string version; reader.str(version);
  if (version != schema && version != media_schema && version != audio_previous_schema && version != execution_schema && version != previous_schema) throw ProtocolError("unsupported presentation schema");
  Presentation result; presentation(reader, result, version == schema ? 15 : version == media_schema ? 14 : version == audio_previous_schema ? 13 : version == execution_schema ? 12 : 11);
  if (reader.offset != bytes.size()) throw ProtocolError("trailing presentation bytes");
  return result;
}
void send_presentation(Channel &channel, std::uint64_t generation, std::uint64_t request,
                       const Presentation &value, std::chrono::milliseconds timeout, bool live) {
  const auto bytes = encode_presentation(value);
  channel.send({live ? Kind::LiveBegin : Kind::SnapshotBegin, generation, request, {schema, std::to_string(bytes.size())}}, timeout);
  for (std::size_t offset = 0; offset < bytes.size(); offset += kPresentationChunkBytes)
    channel.send({live ? Kind::LiveChunk : Kind::SnapshotChunk, generation, request,
                  {std::to_string(offset), bytes.substr(offset, kPresentationChunkBytes)}}, timeout);
  channel.send({live ? Kind::LiveEnd : Kind::Result, generation, request, {schema}}, timeout);
}
PresentationAssembler::PresentationAssembler(std::uint64_t generation, std::uint64_t request, bool live)
    : generation_(generation), request_(request), live_(live) {
  if (!generation || !request) throw ProtocolError("invalid presentation identity");
}
std::optional<Presentation> PresentationAssembler::accept(const Message &message) {
  try {
    if (state_ == State::Complete || state_ == State::Failed)
      throw ProtocolError("presentation assembler is closed");
    if (message.generation != generation_ || message.request != request_)
      throw ProtocolError("stale presentation identity");
    if (message.kind == (live_ ? Kind::LiveBegin : Kind::SnapshotBegin)) {
      if (state_ != State::Empty || message.fields.size() != 2 ||
          (message.fields[0] != schema && message.fields[0] != media_schema && message.fields[0] != audio_previous_schema && message.fields[0] != execution_schema && message.fields[0] != previous_schema))
        throw ProtocolError("invalid presentation begin");
      expected_ = size_field(message.fields[1]);
      schema_ = message.fields[0];
      if (!expected_ || expected_ > kMaxPresentationBytes) throw ProtocolError("invalid presentation size");
      state_ = State::Receiving;
    } else if (message.kind == (live_ ? Kind::LiveChunk : Kind::SnapshotChunk)) {
      if (state_ != State::Receiving || message.fields.size() != 2 ||
          size_field(message.fields[0]) != bytes_.size() || message.fields[1].empty() ||
          message.fields[1].size() > kPresentationChunkBytes ||
          message.fields[1].size() > expected_ - bytes_.size())
        throw ProtocolError("invalid presentation chunk");
      bytes_ += message.fields[1];
    } else if (message.kind == (live_ ? Kind::LiveEnd : Kind::Result)) {
      if (state_ != State::Receiving || message.fields != std::vector<std::string>{schema_} || bytes_.size() != expected_)
        throw ProtocolError("incomplete presentation result");
      auto result = decode_presentation(bytes_);
      std::string{}.swap(bytes_); state_ = State::Complete;
      return result;
    } else throw ProtocolError("unexpected presentation message");
    return std::nullopt;
  } catch (...) {
    std::string{}.swap(bytes_); state_ = State::Failed;
    throw;
  }
}

RunOutputCapture::RunOutputCapture(Session &session)
    : session_(session), previous_(session.output_observer),
      sinks_(std::make_shared<std::vector<std::pair<CellId, Sinks>>>()) {
  session_.output_observer = [sinks = sinks_, previous = previous_](CellId id, auto out, auto err) {
    if (previous) previous(id, out, err);
    sinks->push_back({id, {std::move(out), std::move(err)}});
  };
}
RunOutputCapture::~RunOutputCapture() { session_.output_observer = std::move(previous_); }
void RunOutputCapture::finish() {
  // Keep every attempt until drain so even superseded writers are closed.
  // Iteration order makes the latest attempt's snapshot win for each cell.
  for (const auto &[id, sinks] : *sinks_) {
    std::vector<runtime::RuntimeTextOutputEvent> events;
    for (const auto &sink : {sinks.first, sinks.second}) {
      if (!sink) continue;
      sink->close();
      auto captured = sink->events();
      events.insert(events.end(), std::make_move_iterator(captured.begin()), std::make_move_iterator(captured.end()));
    }
    std::sort(events.begin(), events.end(), [](const auto &a, const auto &b) { return a.order < b.order; });
    if (!id) session_.environment_output = std::move(events);
    else for (auto &cell : session_.cells) if (cell.id == id) { cell.output_events = std::move(events); break; }
  }
  sinks_->clear();
}
}
