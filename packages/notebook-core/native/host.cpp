#include "runtime/sputnik_ext.h"
#include "notebook/core/worker/process.h"
#include "notebook/core/worker/presentation.h"
#include <filesystem>
#include <fstream>
#include <sys/stat.h>
#include <cstring>
#include <charconv>
#include <cmath>
#include <limits>
#include <set>
#include <map>
#include <memory>
#include <thread>
#include <unistd.h>
#include <spawn.h>
#include <signal.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <cerrno>
#include <chrono>
#include <mutex>
#include <cstdlib>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif
extern char **environ;
using namespace sputnik::notebook::worker;
using namespace std::chrono_literals;
static std::string quote(const std::string &value) {
  std::string out = "\"";
  const char *hex = "0123456789abcdef";
  for (unsigned char c : value) {
    if (c == '"' || c == '\\') { out += '\\'; out += static_cast<char>(c); }
    else if (c < 32) { out += "\\u00"; out += hex[c >> 4]; out += hex[c & 15]; }
    else out += static_cast<char>(c);
  }
  return out + '"';
}
static std::string json_real(double value) {
  if (!std::isfinite(value)) throw ProtocolError("non-finite presentation number");
  char buffer[64];
  const auto result = std::to_chars(buffer, buffer + sizeof(buffer), value,
                                  std::chars_format::general, std::numeric_limits<double>::max_digits10);
  if (result.ec != std::errc{}) throw ProtocolError("invalid presentation number");
  return std::string(buffer, result.ptr);
}
static std::string summary(const Presentation &p) {
  std::string out = "{\"cancelled\":" + std::string(p.cancelled ? "true" : "false") +
      ",\"status\":" + quote(p.status) + ",\"environment_error\":" + quote(p.environment_error) +
      ",\"executing_cell\":" + quote(p.executing_cell ? std::to_string(p.executing_cell) : "") +
      ",\"environment_stale\":" + (p.environment_stale ? "true" : "false") + ",\"cells\":[";
  bool first = true;
  for (const auto &c : p.cells) {
    if (!first) out += ',';
    first = false;
    out += "{\"id\":" + quote(std::to_string(c.id)) + ",\"source_revision\":" +
        quote(std::to_string(c.source_revision)) + ",\"ok\":" + (c.ok ? "true" : "false") +
        ",\"dirty\":" + (c.dirty ? "true" : "false") + ",\"result\":" + quote(c.result) +
        ",\"error\":" + quote(c.error) + ",\"output\":[";
    bool first_output = true;
    for (const auto &e : c.output) {
      if (!first_output) out += ',';
      first_output = false;
      out += "{\"stream\":" + quote(e.stream) + ",\"text\":" + quote(e.text) +
          ",\"order\":" + quote(std::to_string(e.order)) + '}';
    }
    out += "],\"progress\":[";
    bool first_progress = true;
    for (const auto &e : c.progress) {
      if (!first_progress) out += ',';
      first_progress = false;
      out += "{\"id\":" + quote(e.id) + ",\"current\":" + json_real(e.current) +
          ",\"total\":" + json_real(e.total) + ",\"done\":" + (e.done ? "true" : "false") + '}';
    }
    out += "]}";
  }
  out += "],\"unobserved_task_failures\":[";
  first = true;
  for (const auto &e : p.unobserved_task_failures) {
    if (!first) out += ',';
    first = false;
    out += "{\"id\":" + quote(std::to_string(e.task_id)) + ",\"name\":" +
        quote(e.error_name) + ",\"message\":" + quote(e.message) + '}';
  }
  return out + "]}";
}

// A transport adapter, not a second binary decoder. Keep the native/Swift
// presentation codec's validation and export only inert public presentation fields.
static std::string media_base64(const std::string &bytes) {
  constexpr char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  out.reserve((bytes.size() + 2) / 3 * 4);
  for (std::size_t i = 0; i < bytes.size(); i += 3) {
    const unsigned a = static_cast<unsigned char>(bytes[i]);
    const unsigned b = i + 1 < bytes.size() ? static_cast<unsigned char>(bytes[i + 1]) : 0;
    const unsigned c = i + 2 < bytes.size() ? static_cast<unsigned char>(bytes[i + 2]) : 0;
    out += alphabet[a >> 2]; out += alphabet[((a & 3) << 4) | (b >> 4)];
    out += i + 1 < bytes.size() ? alphabet[((b & 15) << 2) | (c >> 6)] : '=';
    out += i + 2 < bytes.size() ? alphabet[c & 63] : '=';
  }
  return out;
}
static constexpr std::size_t kMaxSnapshotJSON = 32U * 1024U * 1024U;
static std::string bounded_text(const std::string &text, std::size_t limit, bool &truncated) {
  std::size_t end = 0, count = 0;
  while (end < text.size() && count < limit) {
    ++end;
    while (end < text.size() && (static_cast<unsigned char>(text[end]) & 0xc0) == 0x80) ++end;
    ++count;
  }
  truncated = end < text.size();
  return text.substr(0, end);
}
static std::string trim_text_name(const std::string &text) {
  std::size_t first = text.size(), last = 0;
  for (std::size_t at = 0; at < text.size();) {
    const auto start = at; const auto byte = static_cast<unsigned char>(text[at++]);
    std::uint32_t scalar = byte;
    unsigned tails = 0;
    if ((byte & 0xe0) == 0xc0) { scalar = byte & 0x1f; tails = 1; }
    else if ((byte & 0xf0) == 0xe0) { scalar = byte & 0x0f; tails = 2; }
    else if ((byte & 0xf8) == 0xf0) { scalar = byte & 7; tails = 3; }
    while (tails > 0 && at < text.size()) { --tails; scalar = (scalar << 6) | (static_cast<unsigned char>(text[at++]) & 0x3f); }
    const bool space = scalar == 9 || scalar == 11 || scalar == 12 || scalar == 32 || scalar == 0x85 || scalar == 0xa0 || scalar == 0x1680 ||
        (scalar >= 0x2000 && scalar <= 0x200a) || scalar == 0x2028 || scalar == 0x2029 || scalar == 0x202f || scalar == 0x205f || scalar == 0x3000;
    if (!space) { if (first == text.size()) first = start; last = at; }
  }
  return last > first ? text.substr(first, last - first) : std::string();
}
static std::string diagnostic_json(const CellPresentation &cell) {
  std::string json = ",\"diagnostics\":[";
  std::size_t count = 0;
  for (const auto &error : cell.errors) {
    if (count == 100) break;
    if (count++) json += ',';
    bool truncated = false;
    json += "{\"message\":" + quote(bounded_text(error.message, 4096, truncated)) +
        ",\"truncated\":" + (truncated ? "true" : "false") + ",\"range\":";
    if (error.has_range) {
      const auto &r = error.range;
      json += "{\"start_line\":" + std::to_string(r.start_line) + ",\"start_column\":" + std::to_string(r.start_column) +
          ",\"end_line\":" + std::to_string(r.end_line) + ",\"end_column\":" + std::to_string(r.end_column) +
          ",\"whole_line\":" + (r.whole_line ? "true" : "false") + '}';
    } else json += "null";
    json += '}';
  }
  return json + "],\"diagnostics_truncated\":" + (cell.errors.size() > 100 ? "true" : "false");
}
// Task file names are private worker paths. Export only cell identities and line
// numbers; the web adapter checks them against the immutable execution source.
static std::string tasks_json(const Presentation &p) {
  if (!p.telemetry_updated) return "null";
  const auto &t = p.telemetry;
  if (!t.sampled_ms && !t.revision && !t.cpu_percent && !t.resident_bytes && t.tasks.empty()) return "null";
  std::string json = "{\"revision\":" + quote(std::to_string(t.revision)) +
      ",\"active\":" + quote(std::to_string(t.active)) + ",\"total\":" + quote(std::to_string(t.total)) +
      ",\"dropped\":" + quote(std::to_string(t.dropped)) + ",\"sampled_ms\":" + quote(std::to_string(t.sampled_ms)) +
      ",\"cpu_percent\":" + (t.cpu_percent ? json_real(*t.cpu_percent) : "null") +
      ",\"resident_bytes\":" + (t.resident_bytes ? quote(std::to_string(*t.resident_bytes)) : "null") + ",\"tasks\":[";
  for (std::size_t i = 0; i < t.tasks.size(); ++i) {
    if (i) json += ',';
    const auto &task = t.tasks[i];
    json += "{\"id\":" + quote(std::to_string(task.id)) + ",\"parent\":" + quote(std::to_string(task.parent)) +
        ",\"cell\":" + quote(std::to_string(task.cell)) + ",\"line\":" + quote(std::to_string(task.line)) +
        ",\"elapsed_ms\":" + quote(std::to_string(task.elapsed_ms)) + ",\"state\":" + quote(task.state) +
        ",\"error\":" + quote(task.error) + '}';
  }
  return json + "]}";
}
// Prose comes from the immutable execution document, in authored order. Text
// cells can request only preceding providers; boards use the controller sheet.
static std::set<std::pair<std::string, std::string>> text_bindings(SputnikCtx *cx, SputnikValue sources, bool &limited) {
  if (!sputnik_is_list(cx, sources) || sputnik_list_len(cx, sources) > 262144) throw ProtocolError("invalid text sources");
  std::vector<std::string> preceding;
  std::set<std::string> names;
  std::map<std::string, std::size_t> processed;
  std::set<std::pair<std::string, std::string>> requested;
  std::size_t total = 0;
  for (std::size_t i = 0; i < sputnik_list_len(cx, sources); ++i) {
    const auto item = sputnik_list_at(cx, sources, i);
    if (!sputnik_is_list(cx, item) || sputnik_list_len(cx, item) != 3) throw ProtocolError("invalid text source");
    std::string values[3];
    for (std::size_t j = 0; j < 3; ++j) {
      const char *ptr = nullptr; std::size_t size = 0;
      if (!sputnik_str_view(cx, sputnik_list_at(cx, item, j), &ptr, &size)) throw ProtocolError("invalid text source");
      total += size;
      if (total > 8U * 1024U * 1024U) throw ProtocolError("text sources exceed size limit");
      values[j].assign(ptr, size);
    }
    const auto &id = values[0], &kind = values[1], &text = values[2];
    if (kind == "code") { preceding.push_back(id); continue; }
    if (limited) continue;
    auto request = [&](const std::string &name) {
      if (name.empty() || name.size() > 256) return;
      names.insert(name);
      if (names.size() > 256) { limited = true; requested.clear(); return; }
      if (kind == "binding") requested.emplace(id, name);
      else {
        auto &count = processed[name];
        while (count < preceding.size()) {
          requested.emplace(preceding[count++], name);
          if (requested.size() > 65536) { limited = true; requested.clear(); return; }
        }
      }
      if (requested.size() > 65536) { limited = true; requested.clear(); }
    };
    if (kind == "binding") { request(text); continue; }
    if (kind != "text" && kind != "board") continue;
    std::size_t at = 0;
    while ((at = text.find("{{", at)) != std::string::npos) {
      const auto end = text.find_first_of("{}\r\n", at + 2);
      if (end != std::string::npos && text.compare(end, 2, "}}") == 0) {
        request(trim_text_name(text.substr(at + 2, end - at - 2)));
        at = end + 2;
      } else at += 2;
      if (limited) break;
    }
  }
  return requested;
}
static bool rich_mime(const std::string &mime) {
  return mime == "image/png" || mime == "image/jpeg" || mime == "application/vnd.sputnik.plot+json" || mime == "application/vnd.sputnik.table+json";
}
static std::string figure_json(const sputnik::runtime::NotebookDisplay &d) {
  return "{\"id\":" + quote(d.id) + ",\"mime\":" + quote(d.mime) + ",\"caption\":" + quote(d.caption) +
    ",\"width\":" + std::to_string(d.width) + ",\"height\":" + std::to_string(d.height) +
    ",\"data\":" + quote(d.mime == "application/vnd.sputnik.table+json" ? d.bytes : media_base64(d.bytes)) +
    ",\"plot_scene\":" + quote(d.plot_scene) + '}';
}
static void telemetry_json(std::string &json, const CellPresentation &cell) {
  json += ",\"elapsed_ms\":" + (cell.elapsed_ms ? quote(std::to_string(*cell.elapsed_ms)) : "null") +
      ",\"timing_running\":" + (cell.timing_running ? "true" : "false") + ",\"progress\":[";
  bool first = true;
  for (const auto &item : cell.progress) {
    if (!first) json += ','; first = false;
    json += "{\"id\":" + quote(item.id) + ",\"current\":" + json_real(item.current) +
        ",\"total\":" + json_real(item.total) + ",\"description\":" + quote(item.description) +
        ",\"done\":" + (item.done ? "true" : "false") + ",\"elapsed_ms\":" + quote(std::to_string(item.elapsed_ms)) + '}';
    if (json.size() > kMaxSnapshotJSON) throw ProtocolError("runtime snapshot exceeds size limit");
  }
  json += "],\"stopwatches\":[";
  first = true;
  for (const auto &item : cell.stopwatches) {
    if (!first) json += ','; first = false;
    json += "{\"id\":" + quote(item.id) + ",\"elapsed_ms\":" + quote(std::to_string(item.elapsed_ms)) +
        ",\"done\":" + (item.done ? "true" : "false") + '}';
  }
  json += "],\"charts\":[";
  first = true;
  for (const auto &chart : cell.charts) {
    if (!first) json += ','; first = false;
    json += "{\"id\":" + quote(chart.id) + ",\"total_points\":" + quote(std::to_string(chart.chart_total_points)) + ",\"points\":[";
    bool first_point = true;
    for (const auto &point : chart.chart_points) {
      if (!first_point) json += ','; first_point = false;
      json += '[' + json_real(point[0]) + ',' + json_real(point[1]) + ']';
      if (json.size() > kMaxSnapshotJSON) throw ProtocolError("runtime snapshot exceeds size limit");
    }
    json += "]}";
  }
  json += ']';
}
static const std::string empty_audio = ",\"audio\":[],\"audio_controls\":[],\"audio_limited\":false";
// The validated worker codec owns SPKA/PCM decoding. Web receives inert bytes
// and bounded metadata, never paths or device/VM handles. Reserve the existing
// rich projection first so audio limits cannot discard unrelated results.
static std::string audio_json(const CellPresentation &cell, std::size_t &budget,
                              std::size_t &bytes, std::size_t &count, std::size_t &controls) {
  std::string assets, commands;
  bool limited = false;
  auto add = [&](const std::string &id, const std::string &caption,
                 const sputnik::runtime::AudioDisplay &player,
                 const sputnik::runtime::NotebookAudioEvent *stream) {
    const auto &data = stream ? stream->bytes : player.bytes;
    const std::size_t estimate = (data.size() + 2) / 3 * 4 + caption.size() * 6 + id.size() * 6 + 1024;
    if (count >= 64 || data.size() > 16U * 1024U * 1024U - bytes || estimate > budget ||
        (stream && (!stream->replace || stream->offset != 0))) { limited = true; return; }
    std::string value = "{\"id\":" + quote(id) + ",\"caption\":" + quote(caption) +
      ",\"kind\":" + quote(stream ? "stream" : "file") + ",\"format\":" + quote(stream ? stream->sample_format : player.format) +
      ",\"data\":" + quote(media_base64(data)) + ",\"position\":" + json_real(player.position) +
      ",\"volume\":" + json_real(player.volume) + ",\"waveform\":" + (player.waveform ? "true" : "false") +
      ",\"loop\":" + (player.loop ? "true" : "false") + ",\"autoplay\":" + (player.autoplay ? "true" : "false");
    if (stream) value += ",\"token\":" + quote(std::to_string(stream->token)) + ",\"revision\":" + quote(std::to_string(stream->revision)) +
      ",\"frames\":" + quote(std::to_string(stream->frames)) + ",\"rate\":" + std::to_string(stream->rate) +
      ",\"channels\":" + std::to_string(stream->channels) + ",\"finished\":" + (stream->finished ? "true" : "false");
    value += '}';
    const auto cost = value.size() + (assets.empty() ? 0 : 1);
    if (cost > budget) { limited = true; return; }
    budget -= cost; bytes += data.size(); ++count;
    if (!assets.empty()) assets += ',';
    assets += value;
  };
  std::set<std::string> stream_ids;
  for (const auto &event : cell.audio) if (!event.id.empty()) stream_ids.insert(event.id);
  for (const auto &display : cell.displays) if (display.mime == sputnik::runtime::kAudioMime && !stream_ids.count(display.id))
    add(display.id, display.caption, sputnik::runtime::audio_decode(display.bytes), nullptr);
  for (const auto &event : cell.audio) add(event.id, event.caption, event.audio.player, &event.audio);
  for (const auto &event : cell.audio_controls) {
    if (controls >= 256 || budget < 2048) { limited = true; continue; }
    const auto &control = event.audio_control;
    std::string value = "{\"cell\":" + quote(std::to_string(control.cell)) + ",\"channel\":" + quote(control.channel) + ",\"playback_revision\":" + quote(std::to_string(control.playback_revision)) +
      ",\"seek_revision\":" + quote(std::to_string(control.seek_revision)) + ",\"volume_revision\":" + quote(std::to_string(control.volume_revision)) +
      ",\"playback\":" + std::to_string(control.playback) + ",\"position\":" + json_real(control.position) + ",\"volume\":" + json_real(control.volume) + '}';
    budget -= value.size() + (commands.empty() ? 0 : 1); ++controls;
    if (!commands.empty()) commands += ',';
    commands += value;
  }
  return ",\"audio\":[" + assets + "],\"audio_controls\":[" + commands + "],\"audio_limited\":" + (limited ? "true" : "false");
}
extern "C" SputnikStatus nb_core_presentation_snapshot(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
  try {
    const uint8_t *data = nullptr; size_t size = 0;
    if ((argc < 1 || argc > 3) || !sputnik_bytes_view(cx, args[0], &data, &size)) return sputnik_fault(cx, "TypeError", "expected presentation Bytes");
    std::set<std::pair<std::string, std::string>> bindings;
    if (argc >= 2) {
      if (!sputnik_is_list(cx, args[1]) || sputnik_list_len(cx, args[1]) > 262144) throw ProtocolError("invalid metric bindings");
      std::size_t total = 0;
      for (std::size_t i = 0; i < sputnik_list_len(cx, args[1]); ++i) {
        const auto pair = sputnik_list_at(cx, args[1], i);
        if (!sputnik_is_list(cx, pair) || sputnik_list_len(cx, pair) != 2) throw ProtocolError("invalid metric binding");
        const char *cell = nullptr, *name = nullptr; std::size_t cell_size = 0, name_size = 0;
        if (!sputnik_str_view(cx, sputnik_list_at(cx, pair, 0), &cell, &cell_size) ||
            !sputnik_str_view(cx, sputnik_list_at(cx, pair, 1), &name, &name_size) ||
            cell_size == 0 || cell_size > 20 || name_size == 0 || name_size > 65536)
          throw ProtocolError("invalid metric binding");
        total += cell_size + name_size;
        if (total > 8U * 1024U * 1024U) throw ProtocolError("metric bindings exceed size limit");
        bindings.emplace(std::string(cell, cell_size), std::string(name, name_size));
      }
    }
    if (!size || size > kMaxPresentationBytes) throw ProtocolError("presentation exceeds size limit");
    const auto p = decode_presentation(std::string(reinterpret_cast<const char *>(data), size));
    bool text_limited = false;
    const auto requested = argc == 3 ? text_bindings(cx, args[2], text_limited) : std::set<std::pair<std::string, std::string>>{};
    std::map<std::uint64_t, std::string> text_values;
    std::size_t text_count = 0, text_bytes = 0;
    for (const auto &cell : p.cells) for (const auto &local : cell.locals) {
      if (text_limited || local.role != "module_cell" || !requested.count({std::to_string(cell.id), local.name})) continue;
      bool truncated = false;
      const auto text = bounded_text(local.text_value, 4096, truncated);
      text_bytes += text.size() + local.name.size();
      if (++text_count > 256 || text_bytes > 1024U * 1024U) { text_limited = true; text_values.clear(); continue; }
      auto &value = text_values[cell.id];
      if (!value.empty()) value += ',';
      value += "{\"name\":" + quote(local.name) + ",\"value\":" + (local.initialized ? quote(text) : "null") +
          ",\"initialized\":" + (local.initialized ? "true" : "false") + ",\"truncated\":" + (truncated ? "true" : "false") + '}';
    }
    std::string json = "{\"cells\":[";
    std::vector<std::pair<std::size_t, std::size_t>> audio_ranges;
    for (std::size_t i = 0; i < p.cells.size(); ++i) {
      if (i) json += ',';
      const auto &c = p.cells[i];
      json += "{\"id\":" + quote(std::to_string(c.id)) + ",\"source_revision\":" + quote(std::to_string(c.source_revision)) +
        ",\"dirty\":" + (c.dirty ? "true" : "false") + ",\"table_json\":" + quote(c.result_format.table_json) +
        ",\"displays\":[";
      bool first = true, unsupported = false;
      for (const auto &d : c.displays) {
        if (!rich_mime(d.mime)) { if (d.mime != sputnik::runtime::kAudioMime) unsupported = true; continue; }
        if (!first) json += ','; first = false;
        json += figure_json(d);
        if (json.size() > kMaxSnapshotJSON) throw ProtocolError("rich snapshot exceeds size limit");
      }
      json += "],\"images\":[";
      for (std::size_t j = 0; j < c.images.size(); ++j) {
        if (j) json += ',';
        const auto &series = c.images[j];
        json += "{\"id\":" + quote(series.id) + ",\"caption\":" + quote(series.caption) + ",\"images\":[";
        for (std::size_t k = 0; k < series.images.size(); ++k) {
          if (k) json += ',';
          json += figure_json(series.images[k]);
          if (json.size() > kMaxSnapshotJSON) throw ProtocolError("rich snapshot exceeds size limit");
        }
        json += "]}";
      }
      json += ']';
      telemetry_json(json, c);
      json += diagnostic_json(c);
      json += ",\"result_format\":{\"pretty\":" + quote(c.result_format.pretty) +
          ",\"is_container\":" + (c.result_format.is_container ? "true" : "false") +
          ",\"truncated\":" + (c.result_format.truncated ? "true" : "false") +
          ",\"pretty_truncated\":" + (c.result_format.pretty_truncated ? "true" : "false") + '}';
      json += ",\"text_values\":[" + text_values[c.id] + "]";
      json += ",\"metrics\":[";
      bool first_metric = true;
      for (const auto &local : c.locals) {
        if (local.role != "module_cell" || !bindings.count({std::to_string(c.id), local.name})) continue;
        if (!first_metric) json += ','; first_metric = false;
        const auto &text = local.text_value.empty() ? local.value : local.text_value;
        const char *begin = text.data(), *end = begin + text.size();
        if (begin != end && *begin == '+') ++begin;
        double number = 0;
        const auto parsed = std::from_chars(begin, end, number, std::chars_format::general);
        const bool valid = local.initialized && text.size() <= 65536 && parsed.ec == std::errc{} && parsed.ptr == end && std::isfinite(number);
        json += "{\"name\":" + quote(local.name) + ",\"value\":" + (valid ? quote(text) : "null") + '}';
        if (json.size() > kMaxSnapshotJSON) throw ProtocolError("bound metrics exceed size limit");
      }
      json += ']';
      json += ",\"unsupported\":" + std::string(unsupported ? "true" : "false");
      const auto start = json.size(); json += empty_audio;
      audio_ranges.emplace_back(start, json.size()); json += '}';
      if (json.size() > kMaxSnapshotJSON) throw ProtocolError("rich snapshot exceeds size limit");
    }
    json += "],\"text_limited\":" + std::string(text_limited ? "true" : "false") +
        ",\"task_telemetry\":" + tasks_json(p) + '}';
    if (json.size() > kMaxSnapshotJSON) throw ProtocolError("rich snapshot exceeds size limit");
    std::size_t budget = kMaxSnapshotJSON - json.size(), audio_bytes = 0, audio_count = 0, controls = 0, copied = 0;
    std::string projected;
    for (std::size_t i = 0; i < p.cells.size(); ++i) {
      projected.append(json, copied, audio_ranges[i].first - copied);
      projected += audio_json(p.cells[i], budget, audio_bytes, audio_count, controls);
      copied = audio_ranges[i].second;
    }
    projected.append(json, copied, json.size() - copied); json = std::move(projected);
    *out = sputnik_make_str(cx, json.data(), json.size()); return SPUTNIK_OK;
  } catch (const std::exception &) { return sputnik_fault(cx, "ValueError", "rich presentation is invalid or exceeds the supported limit"); }
}
extern "C" SputnikStatus nb_core_presentation_bound_snapshot(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
  if (argc != 2) return sputnik_fault(cx, "TypeError", "expected presentation Bytes and bindings");
  return nb_core_presentation_snapshot(cx, args, argc, out);
}
extern "C" SputnikStatus nb_core_presentation_text_snapshot(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
  if (argc != 3) return sputnik_fault(cx, "TypeError", "expected presentation Bytes, metric bindings and authored text sources");
  return nb_core_presentation_snapshot(cx, args, argc, out);
}

namespace {
struct HostWorker {
  Process process;
  std::optional<PresentationAssembler> terminal, live;
  Presentation latest;
  std::uint64_t request = 0;
};
std::string str(SputnikCtx *cx, SputnikValue value) {
  const char *ptr = nullptr; size_t length = 0;
  if (!sputnik_str_view(cx, value, &ptr, &length)) throw ProtocolError("expected Str");
  return {ptr, length};
}
HostWorker *worker(SputnikCtx *cx, SputnikValue self) {
  void *ptr = nullptr;
  if (!sputnik_handle_ptr(cx, self, "notebook.core.Worker", &ptr)) return nullptr;
  return static_cast<HostWorker *>(ptr);
}
SputnikStatus event(SputnikCtx *cx, const char *name, std::uint64_t request,
                    const std::string &text, const std::string *binary, SputnikValue *out) {
  SputnikValue items[4] = {sputnik_make_str(cx, name, strlen(name)),
    sputnik_make_int(cx, request), sputnik_make_str(cx, text.data(), text.size()),
    binary ? sputnik_make_bytes(cx, reinterpret_cast<const uint8_t *>(binary->data()), binary->size()) : sputnik_make_null(cx)};
  *out = sputnik_make_list(cx, items, 4); return SPUTNIK_OK;
}
}
extern "C" SputnikStatus nb_core_worker_new(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
  try {
    if (argc != 4 || !sputnik_is_list(cx, args[2])) throw ProtocolError("Worker expects executable, working directory, grants and environment directory");
    std::vector<std::string> grants;
    for (size_t i = 0; i < sputnik_list_len(cx, args[2]); ++i) grants.push_back(str(cx, sputnik_list_at(cx, args[2], i)));
    auto w = std::make_unique<HostWorker>();
    w->process.start(str(cx, args[0]), str(cx, args[1]), grants, str(cx, args[3]));
    auto ready = w->process.receive(5s);
    if (!ready || ready->kind != Kind::Ready) throw ProtocolError("worker handshake timed out");
    *out = sputnik_make_handle(cx, "notebook.core.Worker", w.get());
    if (!*out) return SPUTNIK_ERR;
    w.release(); return SPUTNIK_OK;
  } catch (const std::exception &e) { return sputnik_fault(cx, "IOError", e.what()); }
}
extern "C" SputnikStatus nb_core_worker_send(SputnikCtx *cx, SputnikValue self, const SputnikValue *args, size_t argc, SputnikValue *out) {
  try {
    auto w = worker(cx, self); if (!w) return SPUTNIK_ERR;
    int64_t kind = 0;
    if (argc != 2 || !sputnik_as_int(cx, args[0], &kind) || !sputnik_is_list(cx, args[1])) throw ProtocolError("invalid worker command");
    if (kind != 2 && kind != 4 && kind != 14 && kind != static_cast<int64_t>(Kind::Inputs) && kind != static_cast<int64_t>(Kind::Watch)) throw ProtocolError("unsupported remote worker command");
    std::vector<std::string> fields;
    for (size_t i = 0; i < sputnik_list_len(cx, args[1]); ++i) fields.push_back(str(cx, sputnik_list_at(cx, args[1], i)));
    w->request = w->process.send(static_cast<Kind>(kind), std::move(fields)).request;
    w->terminal.emplace(w->process.generation(), w->request); w->live.reset(); w->latest = {};
    *out = sputnik_make_int(cx, w->request); return SPUTNIK_OK;
  } catch (const std::exception &e) { return sputnik_fault(cx, "IOError", e.what()); }
}
extern "C" SputnikStatus nb_core_worker_poll(SputnikCtx *cx, SputnikValue self, const SputnikValue *, size_t, SputnikValue *out) {
  try {
    auto w = worker(cx, self); if (!w) return SPUTNIK_ERR;
    if (sputnik_task_cancelled(cx)) return sputnik_fault(cx, "CancelledError", "worker polling cancelled");
    auto message = w->process.receive(100ms);
    *out = sputnik_make_null(cx);
    if (!message) {
      if (w->process.poll_exit()) throw ProtocolError("worker exit confirmed");
      return SPUTNIK_OK;
    }
    const auto kind = message->kind;
    if (kind == Kind::Error) return event(cx, "error", w->request, message->fields.empty() ? "worker error" : message->fields[0], nullptr, out);
    if (kind == Kind::Started || kind == Kind::Draining) return event(cx, kind == Kind::Started ? "started" : "draining", w->request, "", nullptr, out);
    if (kind == Kind::LiveBegin || kind == Kind::LiveChunk || kind == Kind::LiveEnd) {
      if (!w->live) w->live.emplace(w->process.generation(), w->request, true);
      if (auto p = w->live->accept(*message)) {
        merge_live_presentation(w->latest, std::move(*p)); w->live.reset();
        auto binary = encode_presentation(w->latest);
        return event(cx, "live", w->request, summary(w->latest), &binary, out);
      }
      return SPUTNIK_OK;
    }
    if (w->live) throw ProtocolError("incomplete live transfer");
    if (!w->terminal) throw ProtocolError("worker command not started");
    if (auto p = w->terminal->accept(*message)) {
      auto binary = encode_presentation(*p); w->terminal.reset();
      return event(cx, "result", w->request, summary(*p), &binary, out);
    }
    return SPUTNIK_OK;
  } catch (const std::exception &e) { return sputnik_fault(cx, "IOError", e.what()); }
}
extern "C" SputnikStatus nb_core_worker_activity(SputnikCtx *cx, SputnikValue self, const SputnikValue *, size_t, SputnikValue *out) {
  try {
    auto w = worker(cx, self); if (!w) return SPUTNIK_ERR;
    const auto request = w->process.send(Kind::Poll);
    const auto reply = w->process.receive(2s);
    if (!reply || reply->kind != Kind::Result || reply->request != request.request || reply->fields.size() != 1 ||
        (reply->fields[0] != "0" && reply->fields[0] != "1")) throw ProtocolError("invalid worker activity reply");
    *out = sputnik_make_bool(cx, reply->fields[0] == "1"); return SPUTNIK_OK;
  } catch (const std::exception &e) { return sputnik_fault(cx, "IOError", e.what()); }
}
extern "C" SputnikStatus nb_core_worker_stop(SputnikCtx *cx, SputnikValue self, const SputnikValue *args, size_t argc, SputnikValue *out) {
  auto w = worker(cx, self); if (!w) return SPUTNIK_ERR;
  int64_t request = 0; int force = 0;
  if (argc != 2 || !sputnik_as_int(cx, args[0], &request) || request < 0 || !sputnik_as_bool(cx, args[1], &force)) return sputnik_fault(cx, "TypeError", "invalid Stop");
  *out = sputnik_make_bool(cx, force ? w->process.request_force_stop(w->process.generation()) : w->process.request_stop({w->process.generation(), static_cast<std::uint64_t>(request)}));
  return SPUTNIK_OK;
}
extern "C" SputnikStatus nb_core_worker_close(SputnikCtx *cx, SputnikValue self, const SputnikValue *, size_t, SputnikValue *out) {
  try {
    auto w = worker(cx, self); if (!w) return SPUTNIK_ERR;
    w->process.request_force_stop(w->process.generation());
    while (!w->process.poll_exit()) std::this_thread::sleep_for(10ms);
    *out = sputnik_make_null(cx); return SPUTNIK_OK;
  } catch (const std::exception &e) { return sputnik_fault(cx, "IOError", e.what()); }
}
extern "C" SputnikStatus nb_core_worker_pid(SputnikCtx *cx, SputnikValue self, const SputnikValue *, size_t, SputnikValue *out) {
  auto w = worker(cx, self); if (!w) return SPUTNIK_ERR;
  *out = sputnik_make_int(cx, w->process.pid()); return SPUTNIK_OK;
}
extern "C" void nb_core_worker_free(SputnikCtx *, void *ptr) { delete static_cast<HostWorker *>(ptr); }
extern "C" SputnikStatus nb_core_pid(SputnikCtx *cx, const SputnikValue *, size_t, SputnikValue *out) {
  *out = sputnik_make_int(cx, ::getpid()); return SPUTNIK_OK;
}

extern "C" SputnikStatus nb_core_environment(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
  try {
    if (argc != 1) throw ProtocolError("expected environment directory");
    const auto env = Environment::discover(str(cx, args[0]));
    const auto text = "{\"directory\":" + quote(env.directory) + ",\"python\":" + quote(env.python) +
        ",\"gemfile\":" + quote(env.gemfile) + ",\"fingerprint\":" + quote(env.fingerprint) + "}";
    *out = sputnik_make_str(cx, text.data(), text.size()); return SPUTNIK_OK;
  } catch (const std::exception &e) { return sputnik_fault(cx, "ValueError", e.what()); }
}

namespace {
std::string project_identity(const std::filesystem::path &root, const std::string &id) {
  if (id.empty() || id.size() > 128 || id.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") != std::string::npos) return {};
  const auto directory = root / id, marker = directory / ".sputnik-owner";
  if (!std::filesystem::is_directory(std::filesystem::symlink_status(directory)) ||
      !std::filesystem::is_regular_file(std::filesystem::symlink_status(marker))) return {};
  std::ifstream input(marker);
  std::string format, project, token;
  std::getline(input, format); std::getline(input, project); std::getline(input, token);
  if (format != "sputnik-notebook-project.v1" || project != id || token.size() != 32) return {};
  struct stat info{};
  if (::lstat(directory.c_str(), &info)) return {};
  return token + ":" + std::to_string(info.st_dev) + ":" + std::to_string(info.st_ino);
}
}
extern "C" SputnikStatus nb_core_environment_candidates(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
  try {
    if (argc != 1) throw ProtocolError("expected projects directory");
    const auto root = str(cx, args[0]);
    std::string text = "[";
    for (const auto &entry : std::filesystem::directory_iterator(root)) {
      const auto id = entry.path().filename().string(), identity = project_identity(root, id);
      if (identity.empty()) continue;
      if (text.size() > 1) text += ',';
      text += "{\"id\":" + quote(id) + ",\"identity\":" + quote(identity) + "}";
    }
    text += ']';
    *out = sputnik_make_str(cx, text.data(), text.size()); return SPUTNIK_OK;
  } catch (const std::exception &e) { return sputnik_fault(cx, "IOError", e.what()); }
}
extern "C" SputnikStatus nb_core_remove_environment_candidate(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
  try {
    if (argc != 3) throw ProtocolError("expected projects directory, id and identity");
    const auto root = str(cx, args[0]), id = str(cx, args[1]), expected = str(cx, args[2]);
    const auto actual = project_identity(root, id);
    if (actual.empty() || actual != expected) { *out = sputnik_make_bool(cx, false); return SPUTNIK_OK; }
    std::filesystem::remove_all(std::filesystem::path(root) / id); // remove_all does not follow child symlinks.
    *out = sputnik_make_bool(cx, true); return SPUTNIK_OK;
  } catch (const std::exception &e) { return sputnik_fault(cx, "IOError", e.what()); }
}
extern "C" SputnikStatus nb_core_environment_log(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
  try {
    if (argc != 1) throw ProtocolError("expected environment directory");
    const auto root = str(cx, args[0]);
    auto tail = [&](const char *name) {
      std::ifstream input(std::filesystem::path(root) / name, std::ios::binary);
      if (!input) return std::string{};
      input.seekg(0, std::ios::end);
      const auto size = static_cast<std::streamoff>(input.tellg());
      input.seekg(size > 65536 ? size - std::streamoff(65536) : std::streamoff(0));
      return std::string(std::istreambuf_iterator<char>(input), {});
    };
    const auto text = "{\"stdout\":" + quote(tail("stdout.log")) + ",\"stderr\":" + quote(tail("stderr.log")) + "}";
    *out = sputnik_make_str(cx, text.data(), text.size()); return SPUTNIK_OK;
  } catch (const std::exception &e) { return sputnik_fault(cx, "IOError", e.what()); }
}

extern "C" SputnikStatus nb_core_storage_available(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
  try {
    if (argc != 1) throw ProtocolError("expected storage path");
    const auto available = std::filesystem::space(str(cx, args[0])).available;
    *out = sputnik_make_int(cx, static_cast<int64_t>(std::min<uintmax_t>(available, INT64_MAX)));
    return SPUTNIK_OK;
  } catch (const std::exception &e) { return sputnik_fault(cx, "IOError", e.what()); }
}
extern "C" SputnikStatus nb_core_storage_bytes(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
  try {
    if (argc != 1) throw ProtocolError("expected storage path");
    const std::filesystem::path path = str(cx, args[0]);
    uintmax_t bytes = 0;
    const auto add = [&](const auto &file) {
      if (std::filesystem::is_regular_file(std::filesystem::symlink_status(file))) {
        const auto size = std::filesystem::file_size(file);
        if (size > uintmax_t(INT64_MAX) - bytes) throw ProtocolError("storage size overflow");
        bytes += size;
      }
    };
    if (std::filesystem::is_directory(std::filesystem::symlink_status(path))) {
      for (const auto &entry : std::filesystem::recursive_directory_iterator(path)) add(entry.path());
    } else add(path);
    *out = sputnik_make_int(cx, static_cast<int64_t>(bytes));
    return SPUTNIK_OK;
  } catch (const std::exception &e) { return sputnik_fault(cx, "IOError", e.what()); }
}

namespace {
volatile sig_atomic_t service_stop_requested = 0;
std::mutex service_signals_mutex;
bool service_signals_owned = false;
void request_service_stop(int) { service_stop_requested = 1; }

struct ServiceSignals {
  struct sigaction previous_term{}, previous_int{};
  ServiceSignals() {
    std::lock_guard<std::mutex> lock(service_signals_mutex);
    if (service_signals_owned) throw ProtocolError("service signal guard already exists");
    struct sigaction action{};
    action.sa_handler = request_service_stop;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, &previous_term))
      throw ProtocolError("cannot install service SIGTERM handler");
    if (sigaction(SIGINT, &action, &previous_int)) {
      sigaction(SIGTERM, &previous_term, nullptr);
      throw ProtocolError("cannot install service SIGINT handler");
    }
    service_stop_requested = 0;
    service_signals_owned = true;
  }
  ~ServiceSignals() {
    std::lock_guard<std::mutex> lock(service_signals_mutex);
    sigaction(SIGINT, &previous_int, nullptr);
    sigaction(SIGTERM, &previous_term, nullptr);
    service_signals_owned = false;
  }
};

struct ServiceProcess {
  pid_t pid = -1;
  bool reaped = false;
  ServiceProcess(const std::string &program, std::vector<std::string> arguments) {
    arguments.insert(arguments.begin(), program);
    std::vector<char *> argv;
    for (auto &arg : arguments) {
      if (arg.find('\0') != std::string::npos) throw ProtocolError("NUL in service argument");
      argv.push_back(arg.data());
    }
    argv.push_back(nullptr);
    posix_spawn_file_actions_t actions;
    const auto initialized = posix_spawn_file_actions_init(&actions);
    if (initialized) throw ProtocolError(std::strerror(initialized));
    const auto opened = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    const auto status = opened ? opened : posix_spawn(&pid, program.c_str(), &actions, nullptr, argv.data(), environ);
    posix_spawn_file_actions_destroy(&actions);
    if (status) throw ProtocolError("cannot start service child: " + std::string(std::strerror(status)));
  }
  bool running() {
    if (reaped) return false;
    int status = 0;
    pid_t result;
    do { result = waitpid(pid, &status, WNOHANG); } while (result < 0 && errno == EINTR);
    if (result == pid || (result < 0 && errno == ECHILD)) reaped = true;
    else if (result < 0) throw ProtocolError("cannot wait for service child");
    return !reaped;
  }
  void close() {
    if (!running()) return;
    if (::kill(pid, SIGTERM) && errno != ESRCH) throw ProtocolError("cannot stop service child");
    const auto deadline = std::chrono::steady_clock::now() + 10s;
    while (running() && std::chrono::steady_clock::now() < deadline)
      std::this_thread::sleep_for(20ms);
    if (!reaped) {
      if (::kill(pid, SIGKILL) && errno != ESRCH) throw ProtocolError("cannot kill service child");
      int status = 0;
      pid_t result;
      do { result = waitpid(pid, &status, 0); } while (result < 0 && errno == EINTR);
      if (result == pid || (result < 0 && errno == ECHILD)) reaped = true;
      else throw ProtocolError("cannot reap service child");
    }
  }
  ~ServiceProcess() { try { close(); } catch (...) {} }
};

ServiceProcess *service_process(SputnikCtx *cx, SputnikValue self) {
  void *pointer = nullptr;
  return sputnik_handle_ptr(cx, self, "notebook.core.ServiceProcess", &pointer)
      ? static_cast<ServiceProcess *>(pointer) : nullptr;
}
}

extern "C" SputnikStatus nb_core_service_signals_new(SputnikCtx *cx, const SputnikValue *, size_t argc, SputnikValue *out) {
  try {
    if (argc) throw ProtocolError("ServiceSignals takes no arguments");
    auto guard = std::make_unique<ServiceSignals>();
    *out = sputnik_make_handle(cx, "notebook.core.ServiceSignals", guard.get());
    if (!*out) return SPUTNIK_ERR;
    guard.release(); return SPUTNIK_OK;
  } catch (const std::exception &e) { return sputnik_fault(cx, "IOError", e.what()); }
}
extern "C" SputnikStatus nb_core_service_signals_requested(SputnikCtx *cx, SputnikValue self, const SputnikValue *, size_t argc, SputnikValue *out) {
  void *pointer = nullptr;
  if (argc || !sputnik_handle_ptr(cx, self, "notebook.core.ServiceSignals", &pointer)) return SPUTNIK_ERR;
  *out = sputnik_make_bool(cx, service_stop_requested != 0); return SPUTNIK_OK;
}
extern "C" void nb_core_service_signals_free(SputnikCtx *, void *pointer) { delete static_cast<ServiceSignals *>(pointer); }
extern "C" SputnikStatus nb_core_service_process_new(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
  try {
    if (argc != 2 || !sputnik_is_list(cx, args[1])) throw ProtocolError("ServiceProcess expects executable and argument list");
    std::vector<std::string> arguments;
    for (size_t i = 0; i < sputnik_list_len(cx, args[1]); ++i) arguments.push_back(str(cx, sputnik_list_at(cx, args[1], i)));
    auto process = std::make_unique<ServiceProcess>(str(cx, args[0]), std::move(arguments));
    *out = sputnik_make_handle(cx, "notebook.core.ServiceProcess", process.get());
    if (!*out) return SPUTNIK_ERR;
    process.release(); return SPUTNIK_OK;
  } catch (const std::exception &e) { return sputnik_fault(cx, "IOError", e.what()); }
}
extern "C" SputnikStatus nb_core_service_process_pid(SputnikCtx *cx, SputnikValue self, const SputnikValue *, size_t, SputnikValue *out) {
  auto process = service_process(cx, self); if (!process) return SPUTNIK_ERR;
  *out = sputnik_make_int(cx, process->pid); return SPUTNIK_OK;
}
extern "C" SputnikStatus nb_core_service_process_running(SputnikCtx *cx, SputnikValue self, const SputnikValue *, size_t, SputnikValue *out) {
  try {
    auto process = service_process(cx, self); if (!process) return SPUTNIK_ERR;
    *out = sputnik_make_bool(cx, process->running()); return SPUTNIK_OK;
  } catch (const std::exception &e) { return sputnik_fault(cx, "IOError", e.what()); }
}
extern "C" SputnikStatus nb_core_service_process_close(SputnikCtx *cx, SputnikValue self, const SputnikValue *, size_t, SputnikValue *out) {
  try {
    auto process = service_process(cx, self); if (!process) return SPUTNIK_ERR;
    process->close(); *out = sputnik_make_null(cx); return SPUTNIK_OK;
  } catch (const std::exception &e) { return sputnik_fault(cx, "IOError", e.what()); }
}
extern "C" void nb_core_service_process_free(SputnikCtx *, void *pointer) { delete static_cast<ServiceProcess *>(pointer); }
extern "C" SputnikStatus nb_core_executable(SputnikCtx *cx, const SputnikValue *, size_t argc, SputnikValue *out) {
  try {
    if (argc) throw ProtocolError("executable takes no arguments");
#ifdef __APPLE__
    uint32_t size = 0;
    _NSGetExecutablePath(nullptr, &size);
    std::string path(size, '\0');
    if (_NSGetExecutablePath(path.data(), &size)) throw ProtocolError("cannot locate service executable");
    path.resize(std::strlen(path.c_str()));
    path = std::filesystem::canonical(path).string();
#else
    const auto path = std::filesystem::read_symlink("/proc/self/exe").string();
#endif
    *out = sputnik_make_str(cx, path.data(), path.size()); return SPUTNIK_OK;
  } catch (const std::exception &e) { return sputnik_fault(cx, "IOError", e.what()); }
}

static std::filesystem::path notebook_package_home() {
  if (const auto *path = std::getenv("SPUTNIK_PKG_HOME")) if (*path) return std::filesystem::absolute(path);
  if (const auto *home = std::getenv("HOME")) if (*home) return std::filesystem::path(home) / ".sputnik/packages";
  throw ProtocolError("Package storage is unavailable: HOME is unset.");
}
static std::filesystem::path package_reference(const std::string &home, const std::string &relative) {
  namespace fs = std::filesystem;
  const fs::path root(home), name(relative);
  if (!root.is_absolute() || name.empty() || name.is_absolute()) throw ProtocolError("invalid package reference");
  if (fs::is_symlink(fs::symlink_status(root))) throw ProtocolError("symlinked notebook package home");
  for (const auto &part : name) if (part == "." || part == ".." || part.string().empty()) throw ProtocolError("invalid package reference");
  fs::create_directories(root);
  auto parent = root;
  for (const auto &part : name.parent_path()) {
    parent /= part;
    if (fs::is_symlink(fs::symlink_status(parent))) throw ProtocolError("symlinked package reference parent");
    fs::create_directory(parent);
  }
  return root / name;
}
extern "C" SputnikStatus nb_core_package_home(SputnikCtx *cx, const SputnikValue *, size_t, SputnikValue *out) {
  try { const auto path = notebook_package_home().string(); *out = sputnik_make_str(cx, path.data(), path.size()); return SPUTNIK_OK; }
  catch (const std::exception &e) { return sputnik_fault(cx, "IOError", e.what()); }
}
extern "C" SputnikStatus nb_core_package_link(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
  try {
    namespace fs = std::filesystem;
    if (argc != 3) throw ProtocolError("package_link expects source, home and reference");
    const auto source = fs::canonical(str(cx, args[0]));
    const auto shared = fs::canonical(notebook_package_home());
    const auto within = source.lexically_relative(shared);
    if (within.empty() || *within.begin() == ".." || !fs::is_regular_file(source / "modules.index")) throw ProtocolError("package is outside shared storage");
    const auto target = package_reference(str(cx, args[1]), str(cx, args[2]));
    if (fs::exists(target) && fs::canonical(target) == source) { *out = sputnik_make_bool(cx, true); return SPUTNIK_OK; }
    if (fs::exists(target) && !fs::is_symlink(target) && !fs::is_regular_file(target / "modules.index"))
      throw ProtocolError("refusing to replace a directory without an installed package index");
    const auto staging = target.parent_path() / (".link-" + target.filename().string() + "-" + std::to_string(getpid()));
    const auto previous = target.parent_path() / (".previous-" + target.filename().string() + "-" + std::to_string(getpid()));
    if (fs::exists(staging) || fs::exists(previous)) throw ProtocolError("unfinished package reference change");
    fs::create_directory_symlink(source, staging);
    bool moved = false;
    try {
      if (fs::exists(target) || fs::is_symlink(target)) { fs::rename(target, previous); moved = true; }
      fs::rename(staging, target);
    } catch (...) {
      if (moved) fs::rename(previous, target);
      fs::remove(staging); throw;
    }
    if (moved) fs::remove_all(previous); // remove_all never traverses the old symlink.
    *out = sputnik_make_bool(cx, true); return SPUTNIK_OK;
  } catch (const std::exception &e) { return sputnik_fault(cx, "IOError", e.what()); }
}
extern "C" SputnikStatus nb_core_package_unlink(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
  try {
    if (argc != 2) throw ProtocolError("package_unlink expects home and reference");
    const auto target = package_reference(str(cx, args[0]), str(cx, args[1]));
    const bool linked = std::filesystem::is_symlink(std::filesystem::symlink_status(target));
    if (linked) std::filesystem::remove(target);
    *out = sputnik_make_bool(cx, linked); return SPUTNIK_OK;
  } catch (const std::exception &e) { return sputnik_fault(cx, "IOError", e.what()); }
}
extern "C" SputnikStatus nb_core_package_reference(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
  try {
    namespace fs = std::filesystem;
    if (argc != 1) throw ProtocolError("package_reference expects a path");
    const auto path = fs::path(str(cx, args[0]));
    bool valid = false;
    std::error_code error;
    if (fs::is_symlink(fs::symlink_status(path, error))) {
      const auto source = fs::canonical(path, error);
      if (!error) {
        const auto shared = fs::weakly_canonical(notebook_package_home());
        const auto relative = source.lexically_relative(shared);
        valid = !relative.empty() && *relative.begin() != ".." && fs::is_regular_file(source / "modules.index");
      }
    }
    *out = sputnik_make_bool(cx, valid); return SPUTNIK_OK;
  } catch (const std::exception &e) { return sputnik_fault(cx, "IOError", e.what()); }
}
