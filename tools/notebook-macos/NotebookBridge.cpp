#include "tools/notebook-macos/NotebookBridge.h"
#include "tools/notebook-macos/NotebookExecution.h"
#include "tools/notebook-worker/grants.h"
#include "notebook/renderers.h"
#include "runtime/context.h"

#include "notebook/project.h"
#include "tools/isputnik/session.h"
#include "tools/isputnik/tabs.h"

#include <algorithm>
#include <charconv>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <optional>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

struct SputnikNotebook {
  explicit SputnikNotebook(sputnik::notebook::LoadedProject project)
      : tabs(std::move(project)) {}

  ProjectTabs tabs;
  std::size_t runtime_cursor = 0;
  bool commands_started = false;
  bool external = false;
  std::unique_ptr<NotebookExecution> execution;
  // Service runtimes never become editable sheets or persistent document cells.
  std::map<std::string, std::unique_ptr<ProjectTab>> periodic;
};
struct SputnikNotebookControl { std::shared_ptr<NotebookExecutionControl> value; };

namespace {

using TabList = std::vector<std::unique_ptr<ProjectTab>>;

void append_replacement_character(std::string *out) {
  out->append("\xef\xbf\xbd", 3U);
}

// Return a UTF-8 sequence length, or zero for an invalid byte sequence.
std::size_t utf8_sequence_length(std::string_view text, std::size_t offset) {
  const auto byte = [&](std::size_t index) {
    return static_cast<unsigned char>(text[index]);
  };
  if (offset >= text.size())
    return 0U;
  const unsigned char first = byte(offset);
  if (first <= 0x7fU)
    return 1U;
  std::size_t length = 0U;
  if (first >= 0xc2U && first <= 0xdfU)
    length = 2U;
  else if (first >= 0xe0U && first <= 0xefU)
    length = 3U;
  else if (first >= 0xf0U && first <= 0xf4U)
    length = 4U;
  else
    return 0U;
  if (offset + length > text.size())
    return 0U;
  for (std::size_t index = 1U; index < length; ++index) {
    if ((byte(offset + index) & 0xc0U) != 0x80U)
      return 0U;
  }
  const unsigned char second = byte(offset + 1U);
  if ((first == 0xe0U && second < 0xa0U) ||
      (first == 0xedU && second >= 0xa0U) ||
      (first == 0xf0U && second < 0x90U) ||
      (first == 0xf4U && second >= 0x90U))
    return 0U;
  return length;
}

std::string valid_utf8(std::string_view text) {
  std::string result;
  result.reserve(text.size());
  for (std::size_t offset = 0; offset < text.size();) {
    const std::size_t length = utf8_sequence_length(text, offset);
    if (length == 0U) {
      append_replacement_character(&result);
      ++offset;
    } else {
      result.append(text.data() + offset, length);
      offset += length;
    }
  }
  return result;
}

void append_json_string(std::string *out, std::string_view text) {
  static constexpr char hex[] = "0123456789abcdef";
  out->push_back('"');
  for (std::size_t offset = 0; offset < text.size();) {
    const unsigned char byte = static_cast<unsigned char>(text[offset]);
    if (byte >= 0x80U) {
      const std::size_t length = utf8_sequence_length(text, offset);
      if (length == 0U) {
        out->append("\\ufffd");
        ++offset;
      } else {
        out->append(text.data() + offset, length);
        offset += length;
      }
      continue;
    }
    ++offset;
    switch (byte) {
    case '"':
      out->append("\\\"");
      break;
    case '\\':
      out->append("\\\\");
      break;
    case '\b':
      out->append("\\b");
      break;
    case '\f':
      out->append("\\f");
      break;
    case '\n':
      out->append("\\n");
      break;
    case '\r':
      out->append("\\r");
      break;
    case '\t':
      out->append("\\t");
      break;
    default:
      if (byte < 0x20U) {
        out->append("\\u00");
        out->push_back(hex[(byte >> 4U) & 0x0fU]);
        out->push_back(hex[byte & 0x0fU]);
      } else {
        out->push_back(static_cast<char>(byte));
      }
      break;
    }
  }
  out->push_back('"');
}

void append_bool(std::string *out, bool value) {
  out->append(value ? "true" : "false");
}

void append_output(std::string *out,
                   const std::vector<sputnik::runtime::RuntimeTextOutputEvent>
                       &events) {
  out->push_back('[');
  for (std::size_t index = 0; index < events.size(); ++index) {
    if (index != 0U)
      out->push_back(',');
    out->append("{\"stream\":");
    append_json_string(out, events[index].stream);
    out->append(",\"text\":");
    append_json_string(out, events[index].text);
    if (events[index].source.present) {
      out->append(",\"source_file\":"); append_json_string(out, events[index].source.file);
      out->append(",\"source_line\":" + std::to_string(events[index].source.line));
    }
    out->push_back('}');
  }
  out->push_back(']');
}

void set_error(char **destination, std::string_view message) noexcept {
  if (destination == nullptr)
    return;
  *destination = nullptr;
  try {
    const std::string safe = valid_utf8(message);
    char *copy = static_cast<char *>(std::malloc(safe.size() + 1U));
    if (copy == nullptr)
      return;
    if (!safe.empty())
      std::memcpy(copy, safe.data(), safe.size());
    copy[safe.size()] = '\0';
    *destination = copy;
  } catch (...) {
    // Error reporting is best effort if even the diagnostic allocation fails.
  }
}

char *copy_c_string(std::string_view value) {
  if (value.size() == std::numeric_limits<std::size_t>::max())
    throw std::bad_alloc();
  char *copy = static_cast<char *>(std::malloc(value.size() + 1U));
  if (copy == nullptr)
    throw std::bad_alloc();
  if (!value.empty())
    std::memcpy(copy, value.data(), value.size());
  copy[value.size()] = '\0';
  return copy;
}

std::string require_text(const char *text, const char *field) {
  if (text == nullptr)
    throw std::invalid_argument(std::string(field) + " is required");
  return text;
}

struct ParsedTabId {
  bool module = false;
  std::string id;
};

ParsedTabId parse_tab_id(const char *raw) {
  const std::string value = require_text(raw, "tab");
  if (value.rfind("sheet:", 0U) == 0U && value.size() > 6U)
    return {false, value.substr(6U)};
  if (value.rfind("module:", 0U) == 0U && value.size() > 7U)
    return {true, value.substr(7U)};
  throw std::invalid_argument("tab must be sheet:<id> or module:<id>");
}

std::size_t find_tab_index(const SputnikNotebook &notebook,
                           const ParsedTabId &wanted) {
  const TabList &tabs = notebook.tabs.tabs();
  for (std::size_t index = 0; index < tabs.size(); ++index) {
    const ProjectTab &tab = *tabs[index];
    if (tab.module.has_value() != wanted.module)
      continue;
    if (wanted.module ? tab.module->id == wanted.id
                      : tab.session.project_sheet_id == wanted.id)
      return index;
  }
  throw std::invalid_argument("unknown tab: " +
                              std::string(wanted.module ? "module:" : "sheet:") +
                              wanted.id);
}

std::size_t find_cell_index(const Session &session, const char *raw) {
  const std::string value = require_text(raw, "cell");
  if (value.empty() ||
      !std::all_of(value.begin(), value.end(), [](char ch) {
        return ch >= '0' && ch <= '9';
      }))
    throw std::invalid_argument("cell must be a decimal cell ID");
  sputnik::notebook::CellId id = 0;
  const auto result = std::from_chars(value.data(), value.data() + value.size(), id);
  if (result.ec != std::errc{} || result.ptr != value.data() + value.size() ||
      id == 0U || std::to_string(id) != value)
    throw std::invalid_argument("cell must be a canonical decimal cell ID");
  for (std::size_t index = 0; index < session.cells.size(); ++index) {
    if (session.cells[index].id == id)
      return index;
  }
  throw std::invalid_argument("unknown or stale cell ID: " + value);
}

void switch_to_index(SputnikNotebook *notebook, std::size_t index) {
  const std::size_t count = notebook->tabs.tabs().size();
  if (count == 0U || index >= count)
    throw std::out_of_range("tab index out of range");
  const std::size_t current = notebook->tabs.selected();
  if (current == index)
    return;
  const std::size_t forward = index >= current ? index - current
                                               : count - current + index;
  if (forward > static_cast<std::size_t>(std::numeric_limits<int>::max()))
    throw std::out_of_range("tab count exceeds supported selection range");
  (void)notebook->tabs.switch_by(static_cast<int>(forward));
  if (notebook->tabs.selected() != index)
    throw std::runtime_error("could not select requested tab");
}

class SelectionRestore {
public:
  explicit SelectionRestore(SputnikNotebook *notebook)
      : notebook_(notebook), selected_(notebook->tabs.selected()) {}
  ~SelectionRestore() {
    try {
      switch_to_index(notebook_, selected_);
    } catch (...) {
    }
  }
  SelectionRestore(const SelectionRestore &) = delete;
  SelectionRestore &operator=(const SelectionRestore &) = delete;

private:
  SputnikNotebook *notebook_;
  std::size_t selected_;
};

std::string tab_id(const ProjectTab &tab) {
  return tab.module.has_value() ? "module:" + tab.module->id
                                : "sheet:" + tab.session.project_sheet_id;
}

std::string tab_title(const ProjectTab &tab,
                      const sputnik::notebook::LoadedProject &project) {
  if (tab.module.has_value())
    return tab.module->id;
  const auto found = std::find_if(
      project.document.sheets.begin(), project.document.sheets.end(),
      [&](const auto &sheet) { return sheet.id == tab.session.project_sheet_id; });
  return found == project.document.sheets.end() ? tab.session.project_sheet_id
                                                 : found->title;
}

bool module_auto_imported(const ProjectTab &tab,
                          const sputnik::notebook::LoadedProject &project) {
  if (!tab.module.has_value())
    return false;
  return std::find(project.document.auto_imports.begin(),
                   project.document.auto_imports.end(), tab.module->id) !=
         project.document.auto_imports.end();
}

std::string display_base64(const std::string &bytes) {
  static constexpr char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string result;
  result.reserve((bytes.size() + 2) / 3 * 4);
  for (std::size_t i = 0; i < bytes.size(); i += 3) {
    const unsigned a = static_cast<unsigned char>(bytes[i]);
    const unsigned b = i + 1 < bytes.size() ? static_cast<unsigned char>(bytes[i + 1]) : 0;
    const unsigned c = i + 2 < bytes.size() ? static_cast<unsigned char>(bytes[i + 2]) : 0;
    result += alphabet[a >> 2]; result += alphabet[((a & 3) << 4) | (b >> 4)];
    result += i + 1 < bytes.size() ? alphabet[((b & 15) << 2) | (c >> 6)] : '=';
    result += i + 2 < bytes.size() ? alphabet[c & 63] : '=';
  }
  return result;
}

void append_progress(std::string *out, const std::vector<sputnik::runtime::NotebookLiveEvent> &events) {
  out->push_back('[');
  for (std::size_t i = 0; i < events.size(); ++i) {
    if (i) out->push_back(',');
    const auto &p = events[i];
    out->append("{\"id\":"); append_json_string(out, p.id);
    out->append(",\"description\":"); append_json_string(out, p.description);
    out->append(",\"current\":" + std::to_string(p.current));
    out->append(",\"total\":" + std::to_string(p.total));
    out->append(",\"elapsed_ms\":" + std::to_string(p.elapsed_ms));
    out->append(",\"done\":"); append_bool(out, p.done);
    out->push_back('}');
  }
  out->push_back(']');
}

void append_chart_series(std::string *out, const std::vector<sputnik::runtime::NotebookLiveEvent> &events) {
  out->push_back('[');
  for (std::size_t i = 0; i < events.size(); ++i) {
    if (i) out->push_back(',');
    const auto &chart = events[i];
    out->append("{\"id\":"); append_json_string(out, chart.id);
    out->append(",\"total_points\":" + std::to_string(chart.chart_total_points));
    out->append(",\"replace_chart\":"); append_bool(out, chart.replace_chart);
    out->append(",\"points\":[");
    for (std::size_t point = 0; point < chart.chart_points.size(); ++point) {
      if (point) out->push_back(',');
      out->append("{\"x\":");
      char buffer[64];
      auto result = std::to_chars(buffer, buffer + sizeof(buffer), chart.chart_points[point][0],
                                  std::chars_format::general, std::numeric_limits<double>::max_digits10);
      if (result.ec != std::errc{}) throw std::runtime_error("could not serialize chart coordinate");
      out->append(buffer, result.ptr);
      out->append(",\"y\":");
      result = std::to_chars(buffer, buffer + sizeof(buffer), chart.chart_points[point][1],
                             std::chars_format::general, std::numeric_limits<double>::max_digits10);
      if (result.ec != std::errc{}) throw std::runtime_error("could not serialize chart coordinate");
      out->append(buffer, result.ptr);
      out->push_back('}');
    }
    out->append("]}");
  }
  out->push_back(']');
}

void append_displays(std::string *out, const std::vector<sputnik::runtime::NotebookDisplay> &displays) {
  out->push_back('[');
  for (std::size_t i = 0; i < displays.size(); ++i) {
    if (i) out->push_back(',');
    const auto &display = displays[i];
    out->append("{\"mime\":"); append_json_string(out, display.mime);
    out->append(",\"id\":"); append_json_string(out, display.id);
    out->append(",\"caption\":"); append_json_string(out, display.caption);
    out->append(",\"width\":" + std::to_string(display.width));
    out->append(",\"height\":" + std::to_string(display.height));
    out->append(",\"data\":"); append_json_string(out, display_base64(display.bytes));
    out->append(",\"plot_scene\":"); append_json_string(out, display.plot_scene);
    out->push_back('}');
  }
  out->push_back(']');
}

void append_telemetry(std::string *out, const sputnik::runtime::RuntimeRunTelemetry &t) {
  out->append("{\"revision\":" + std::to_string(t.revision) + ",\"dropped\":" + std::to_string(t.dropped) + ",\"active\":" + std::to_string(t.active) + ",\"total\":" + std::to_string(t.total) + ",\"sampled_ms\":" + std::to_string(t.sampled_ms));
  out->append(",\"cpu_percent\":"); out->append(t.cpu_percent ? std::to_string(*t.cpu_percent) : "null");
  out->append(",\"resident_bytes\":"); out->append(t.resident_bytes ? std::to_string(*t.resident_bytes) : "null");
  out->append(",\"tasks\":[");
  for (std::size_t i = 0; i < t.tasks.size(); ++i) {
    if (i) out->append(","); const auto &task = t.tasks[i];
    out->append("{\"id\":"); append_json_string(out, std::to_string(task.id));
    out->append(",\"parent\":"); append_json_string(out, std::to_string(task.parent));
    out->append(",\"cell\":"); append_json_string(out, std::to_string(task.cell));
    out->append(",\"state\":"); append_json_string(out, task.state);
    out->append(",\"error\":"); append_json_string(out, task.error);
    out->append(",\"file\":"); append_json_string(out, task.file);
    out->append(",\"line\":" + std::to_string(task.line) + ",\"elapsed_ms\":" + std::to_string(task.elapsed_ms) + "}");
  }
  out->append("]}");
}
void append_audio_controls(std::string *out, const std::vector<sputnik::runtime::NotebookLiveEvent> &events) {
  out->append("[");
  for (std::size_t i = 0; i < events.size(); ++i) {
    if (i) out->append(","); const auto &c = events[i].audio_control;
    out->append("{\"cell\":"); append_json_string(out, std::to_string(c.cell));
    out->append(",\"channel\":"); append_json_string(out, c.channel);
    auto integer = [&](const char *key, std::uint64_t n) { out->append(",\""); out->append(key); out->append("\":"); out->append(std::to_string(n)); };
    integer("playback_revision", c.playback_revision); integer("seek_revision", c.seek_revision); integer("volume_revision", c.volume_revision); integer("playback", c.playback);
    out->append(",\"position\":"); out->append(std::to_string(c.position));
    out->append(",\"volume\":"); out->append(std::to_string(c.volume)); out->append("}");
  }
  out->append("]");
}
void append_audio_streams(std::string *out, const std::vector<sputnik::runtime::NotebookLiveEvent> &events) {
  out->append("[");
  for (std::size_t i = 0; i < events.size(); ++i) {
    if (i) out->append(",");
    const auto &event = events[i]; const auto &e = event.audio;
    out->append("{\"id\":"); append_json_string(out, event.id);
    out->append(",\"caption\":"); append_json_string(out, event.caption);
    auto integer = [&](const char *key, std::uint64_t value) { out->append(",\""); out->append(key); out->append("\":"); out->append(std::to_string(value)); };
    integer("token", e.token); integer("revision", e.revision); integer("offset", e.offset); integer("frames", e.frames);
    integer("rate", e.rate); integer("channels", e.channels);
    out->append(",\"sample_format\":"); append_json_string(out, e.sample_format);
    out->append(",\"data\":"); append_json_string(out, display_base64(e.bytes));
    out->append(",\"replace\":"); append_bool(out, e.replace);
    out->append(",\"finished\":"); append_bool(out, e.finished);
    out->append(",\"position\":"); out->append(std::to_string(e.player.position));
    out->append(",\"volume\":"); out->append(std::to_string(e.player.volume));
    out->append(",\"waveform\":"); append_bool(out, e.player.waveform);
    out->append(",\"looped\":"); append_bool(out, e.player.loop);
    out->append(",\"autoplay\":"); append_bool(out, e.player.autoplay); out->append("}");
  }
  out->append("]");
}
void append_image_series(std::string *out, const std::vector<sputnik::runtime::NotebookLiveEvent> &events) {
  out->push_back('[');
  for (std::size_t i = 0; i < events.size(); ++i) {
    if (i) out->push_back(',');
    const auto &series = events[i];
    out->append("{\"id\":"); append_json_string(out, series.id);
    out->append(",\"caption\":"); append_json_string(out, series.caption);
    out->append(",\"images\":"); append_displays(out, series.images);
    out->push_back('}');
  }
  out->push_back(']');
}

void append_cell(std::string *out, const Cell &cell) {
  out->append("{\"id\":");
  append_json_string(out, std::to_string(cell.id));
  out->append(",\"kind\":");
  append_json_string(out, cell.kind);
  out->append(",\"source\":");
  append_json_string(out, cell.source);
  out->append(",\"formatting\":");
  append_json_string(out, cell.formatting);
  out->append(",\"watch\":");
  append_bool(out, cell.watch);
  out->append(",\"dirty\":");
  append_bool(out, cell.dirty);
  out->append(",\"ok\":");
  append_bool(out, cell.ok);
  out->append(",\"result\":");
  append_json_string(out, cell.result);
  out->append(",\"result_format\":{\"pretty\":");
  append_json_string(out, cell.result_format.pretty);
  out->append(",\"is_container\":"); append_bool(out, cell.result_format.is_container);
  out->append(",\"truncated\":"); append_bool(out, cell.result_format.truncated);
  out->append(",\"pretty_truncated\":"); append_bool(out, cell.result_format.pretty_truncated);
  out->append(",\"table_json\":"); append_json_string(out, cell.result_format.table_json);
  out->append("}");
  out->append(",\"error\":");
  append_json_string(out, cell.error);
  out->append(",\"output\":");
  append_output(out, cell.output_events);
  out->append(",\"displays\":"); append_displays(out, cell.displays);
  out->append(",\"progress\":"); append_progress(out, cell.progress);
  out->append(",\"charts\":"); append_chart_series(out, cell.charts);
  out->append(",\"images\":"); append_image_series(out, cell.images);
  out->append(",\"audio\":"); append_audio_streams(out, cell.audio);
  out->append(",\"audio_controls\":"); append_audio_controls(out, cell.audio_controls);
  out->append(",\"elapsed_ms\":"); out->append(cell.elapsed_ms ? std::to_string(*cell.elapsed_ms) : "null");
  out->append(",\"stopwatches\":[");
  for (std::size_t i = 0; i < cell.stopwatches.size(); ++i) {
    if (i) *out += ',';
    const auto &timer = cell.stopwatches[i];
    *out += "{\"id\":"; append_json_string(out, timer.id);
    *out += ",\"elapsed_ms\":" + std::to_string(timer.elapsed_ms) + ",\"done\":";
    append_bool(out, timer.done); *out += '}';
  }
  *out += ']';
  out->append(",\"locals\":[");
  for (std::size_t index = 0; index < cell.locals.size(); ++index) {
    if (index != 0U)
      out->push_back(',');
    const LocalView &local = cell.locals[index];
    out->append("{\"name\":");
    append_json_string(out, local.name);
    out->append(",\"value\":");
    append_json_string(out, local.value);
    out->append(",\"text_value\":");
    append_json_string(out, local.text_value);
    out->append(",\"role\":");
    append_json_string(out, local.role);
    out->append(",\"binding_kind\":");
    append_json_string(out, local.binding_kind);
    out->append(",\"initialized\":");
    append_bool(out, local.initialized);
    out->append(",\"watched\":");
    append_bool(out, local.watched);
    out->push_back('}');
  }
  out->append("]}");
}

std::string snapshot_json(const SputnikNotebook &notebook) {
  const sputnik::notebook::LoadedProject &project = notebook.tabs.project();
  const TabList &tabs = notebook.tabs.tabs();
  std::string out;
  out.reserve(2048U);
  out.append("{\"title\":");
  append_json_string(&out, project.document.title);
  out.append(",\"path\":");
  append_json_string(&out, project.directory.string());
  const auto retention = project.document.extra.find("retain_cell_results");
  if (retention != project.document.extra.end() && retention->second != "true" && retention->second != "false")
    throw std::runtime_error("retain_cell_results must be a boolean");
  out.append(",\"retain_cell_results\":");
  append_bool(&out, retention == project.document.extra.end() || retention->second == "true");
  out.append(",\"selected_tab\":");
  append_json_string(&out, tab_id(*tabs[notebook.tabs.selected()]));
  out.append(",\"modified_count\":");
  out.append(std::to_string(notebook.tabs.modified_count()));
  out.append(",\"environment_generation\":");
  out.append(std::to_string(notebook.tabs.environment_generation()));
  out += ",\"dependencies\":[";
  for (std::size_t i = 0; i < project.document.dependencies.size(); ++i) {
    if (i) out += ',';
    out += "{\"path\":"; append_json_string(&out, project.document.dependencies[i].path);
    out += ",\"auto_import\":"; out += project.document.dependencies[i].auto_import ? "true" : "false";
    out += ",\"native\":"; out += project.document.dependencies[i].extra.count("native_library") ? "true}" : "false}";
  }
  out += ']';
  out.append(",\"inputs\":[");
  for (std::size_t i = 0; i < project.document.inputs.size(); ++i) {
    const auto &input = project.document.inputs[i]; if (i) out += ',';
    out += "{\"id\":"; append_json_string(&out, input.id);
    out += ",\"title\":"; append_json_string(&out, input.title);
    out += ",\"type\":"; append_json_string(&out, input.type);
    out += ",\"value_json\":";
    append_json_string(&out, sputnik::notebook::serialize_project_input_value(notebook.tabs.inputs().at(input.id)));
    out += ",\"default_json\":";
    append_json_string(&out, sputnik::notebook::serialize_project_input_value(input.initial));
    if (input.minimum) out += ",\"minimum\":" + sputnik::notebook::serialize_project_input_value(*input.minimum);
    if (input.maximum) out += ",\"maximum\":" + sputnik::notebook::serialize_project_input_value(*input.maximum);
    out += '}';
  }
  out += "],\"boards\":[";
  for (std::size_t i = 0; i < project.document.boards.size(); ++i) {
    if (i) out += ',';
    out += sputnik::notebook::serialize_project_board(project.document.boards[i]);
  }
  out += ']';
  out += ",\"accepted_data\":[";
  bool first_data = true;
  for (const auto &[key, value] : notebook.tabs.inputs()) for (const auto &kind : {std::string("selection"), std::string("annotations"), std::string("audio_annotations")}) {
    const auto prefix = sputnik::runtime::notebook_component_data_key(kind, "");
    if (key.rfind(prefix, 0) != 0) continue;
    if (!first_data) out += ','; first_data = false;
    out += "{\"kind\":"; append_json_string(&out, kind);
    out += ",\"id\":"; append_json_string(&out, key.substr(prefix.size()));
    out += ",\"json\":"; append_json_string(&out, std::get<std::string>(value)); out += '}';
  }
  out += ']';
  out += ",\"audio_inputs\":[";
  bool first_audio_input = true;
  for (const auto &tab : tabs) if (!tab->module && tab->session.project_audio_inputs) {
    for (const auto &[id, input] : *tab->session.project_audio_inputs) {
      if (!first_audio_input) out += ','; first_audio_input = false;
      out += "{\"sheet\":"; append_json_string(&out, tab->session.project_sheet_id);
      out += ",\"id\":"; append_json_string(&out, id);
      out += ",\"name\":"; append_json_string(&out, input.name);
      out += ",\"revision\":"; append_json_string(&out, input.revision);
      out += ",\"panels\":";
      std::vector<sputnik::runtime::NotebookDisplay> panels;
      if (!input.audio.bytes.empty()) {
        sputnik::runtime::NotebookDisplay panel; panel.mime = sputnik::runtime::kAudioMime;
        panel.bytes = sputnik::runtime::audio_encode(input.audio); panel.caption = input.name; panel.id = id; panels.push_back(std::move(panel));
      }
      append_displays(&out, panels); out += '}';
    }
  }
  out += ']';
  out += ",\"image_inputs\":[";
  bool first_image_input = true;
  for (const auto &tab : tabs) if (!tab->module && tab->session.project_images) {
    for (const auto &[id, input] : *tab->session.project_images) {
      if (!first_image_input) out += ',';
      first_image_input = false;
      out += "{\"sheet\":"; append_json_string(&out, tab->session.project_sheet_id);
      out += ",\"id\":"; append_json_string(&out, id);
      out += ",\"caption\":"; append_json_string(&out, input.caption);
      out += ",\"selected\":" + std::to_string(input.selected);
      out += ",\"images\":"; append_displays(&out, input.images); out += '}';
    }
  }
  out += ']';
  out += ",\"periodic_results\":[";
  bool first_periodic = true;
  for (const auto &[key, tab] : notebook.periodic) {
    if (!tab || tab->session.cells.empty()) continue;
    if (!first_periodic) out += ',';
    first_periodic = false;
    const auto &cell = tab->session.cells[0];
    out += "{\"id\":"; append_json_string(&out, key);
    out += ",\"ok\":"; append_bool(&out, cell.ok);
    out += ",\"result\":"; append_json_string(&out, cell.result);
    out += ",\"error\":"; append_json_string(&out, cell.error);
    out += '}';
  }
  out += ']';
  out.append(",\"tabs\":[");
  for (std::size_t index = 0; index < tabs.size(); ++index) {
    if (index != 0U)
      out.push_back(',');
    const ProjectTab &tab = *tabs[index];
    const Session &session = tab.session;
    out.append("{\"id\":");
    append_json_string(&out, tab_id(tab));
    out.append(",\"kind\":");
    append_json_string(&out, tab.module.has_value() ? "module" : "sheet");
    out.append(",\"title\":");
    append_json_string(&out, tab_title(tab, project));
    out.append(",\"modified\":");
    append_bool(&out, notebook.tabs.modified(index));
    out.append(",\"environment_stale\":");
    append_bool(&out, session.environment_stale);
    out.append(",\"auto_import\":");
    append_bool(&out, module_auto_imported(tab, project));
    out.append(",\"status\":");
    append_json_string(&out, session.status);
    out.append(",\"environment_error\":");
    append_json_string(&out, session.environment_error);
    out.append(",\"environment_output\":");
    append_output(&out, session.environment_output);
    out += ",\"telemetry\":"; append_telemetry(&out, session.run_telemetry);
    out.append(",\"selected_cell\":");
    if (session.selected < session.cells.size())
      append_json_string(&out,
                         std::to_string(session.cells[session.selected].id));
    else
      append_json_string(&out, "");
    out.append(",\"cells\":[");
    for (std::size_t cell_index = 0; cell_index < session.cells.size();
         ++cell_index) {
      if (cell_index != 0U)
        out.push_back(',');
      append_cell(&out, session.cells[cell_index]);
      const auto owner = session.cells[cell_index].id;
      for (const auto &sheet : project.document.sheets) for (const auto &saved : sheet.cells) {
        if (saved.id != owner || saved.kind != "code" || !saved.extra.count("cell_ui")) continue;
        const auto &raw = saved.extra.at("cell_ui");
        const auto ui = sputnik::notebook::parse_project_cell_ui(raw);
        out.pop_back(); out += ",\"cell_ui\":" + raw + ",\"cell_inputs\":[";
        for (std::size_t i = 0; i < ui.inputs.size(); ++i) {
          const auto &input = ui.inputs[i]; if (i) out += ',';
          out += "{\"id\":"; append_json_string(&out, input.id);
          out += ",\"title\":"; append_json_string(&out, input.title);
          out += ",\"type\":"; append_json_string(&out, input.type);
          out += ",\"value_json\":";
          append_json_string(&out, sputnik::notebook::serialize_project_input_value(notebook.tabs.inputs().at(sputnik::runtime::notebook_cell_input_key(owner, input.id))));
          out += ",\"default_json\":";
          append_json_string(&out, sputnik::notebook::serialize_project_input_value(input.initial));
          if (input.minimum) out += ",\"minimum\":" + sputnik::notebook::serialize_project_input_value(*input.minimum);
          if (input.maximum) out += ",\"maximum\":" + sputnik::notebook::serialize_project_input_value(*input.maximum);
          out += '}';
        }
        out += "]}";
      }
    }
    out.append("]}");
  }
  out.append("]}");
  return out;
}

void clear_errors_from(Session *session, std::size_t index) {
  for (std::size_t cursor = index; cursor < session->cells.size(); ++cursor) {
    Cell &cell = session->cells[cursor];
    cell.error_ranges.clear();
    cell.errors.clear();
    cell.selected_error = 0U;
  }
}

void mark_source_edit(Session *session, std::size_t index,
                      const std::string &source) {
  Cell &cell = session->cells[index];
  cell.source = source;
  cell.cursor = source.size();
  cell.dirty = true;
  session->document_dirty = true;
  clear_errors_from(session, index);
  session->status = "cell edited";
}

void validate_editable_source(std::string_view source,
                              std::string_view description) {
  for (std::size_t offset = 0; offset < source.size();) {
    if (source[offset] == '\0')
      throw std::runtime_error(std::string(description) +
                               " contains an embedded NUL byte");
    const std::size_t length = utf8_sequence_length(source, offset);
    if (length == 0U)
      throw std::runtime_error(std::string(description) + " is not valid UTF-8");
    offset += length;
  }
}

void validate_project_sources(const SputnikNotebook &notebook) {
  for (const auto &tab : notebook.tabs.tabs()) {
    for (const Cell &cell : tab->session.cells) {
      if (cell.kind == "code" || cell.kind == "text") {
        validate_editable_source(cell.source,
                                 tab_id(*tab) + " cell " +
                                     std::to_string(cell.id) + " source");
      }
    }
  }
}

void require_sheet_cell_editable(const ProjectTab &tab, const Cell &cell,
                                 std::string_view operation) {
  if (tab.module.has_value())
    throw std::invalid_argument(std::string(operation) +
                                " is not supported in a module editor");
  if (cell.kind != "code" && cell.kind != "text")
    throw std::invalid_argument("opaque cells are read-only");
}

void move_cell(Session *session, std::size_t index, bool up) {
  if (session->module_editor)
    throw std::invalid_argument("module editor has one source buffer");
  if (session->cells[index].kind != "code" && session->cells[index].kind != "text")
    throw std::invalid_argument("opaque cells cannot be moved");
  const std::size_t next = up ? (index == 0U ? 0U : index - 1U)
                              : std::min(index + 1U, session->cells.size() - 1U);
  if (next == index)
    throw std::invalid_argument(up ? "cell is already first" : "cell is already last");
  const bool code_order_changed = session->cells[index].kind == "code" &&
                                  session->cells[next].kind == "code";
  std::swap(session->cells[index], session->cells[next]);
  session->selected = next;
  session->document_dirty = true;
  for (Cell &cell : session->cells) {
    if (code_order_changed && cell.kind == "code")
      cell.dirty = true;
    if (code_order_changed) {
      cell.error_ranges.clear();
      cell.errors.clear();
      cell.selected_error = 0U;
    }
  }
  session->status = "cell moved";
}

void command_impl(SputnikNotebook *notebook, const char *action_raw,
                  const char *tab_raw, const char *cell_raw,
                  const char *text_raw) {
  if (notebook == nullptr)
    throw std::invalid_argument("notebook handle is null");
  const std::string action = require_text(action_raw, "action");
  if (notebook->external && (action == "run" || action == "run_all" || action == "watch_run" || action == "apply" ||
      action == "restart_worker" || action == "worker_grants" || action == "worker_environment" || action == "set_input" || action == "set_inputs" ||
      action == "action_run" || action == "periodic_run" || action == "periodic_tick" || action == "watch_run"))
    throw std::runtime_error("This operation must be handled by the remote backend.");
  notebook->commands_started = true;
  if (action == "retain_cell_results") {
    const auto value = require_text(text_raw, "retention setting");
    if (value != "on" && value != "off") throw std::invalid_argument("retention setting must be on or off");
    notebook->tabs.set_retain_cell_results(value == "on");
    return;
  }
  if (action == "add_dependency" || action == "remove_dependency") {
    const auto path = require_text(text_raw, "dependency path");
    if (action == "add_dependency") notebook->tabs.add_dependency(path);
    else notebook->tabs.remove_dependency(path);
    return;
  }
  if (action == "set_input" || action == "set_inputs") {
    const auto values = action == "set_inputs"
        ? sputnik::notebook::parse_project_input_edits(require_text(text_raw, "input batch JSON"))
        : std::map<std::string, std::string>{{require_text(cell_raw, "input id"), require_text(text_raw, "value JSON")}};
    const bool changed = notebook->tabs.set_inputs(values, !notebook->execution);
    if (changed && notebook->execution) notebook->execution->inputs_changed(notebook->tabs);
    return;
  }
  if (action == "set_cell_inputs" || action == "save_cell_ui") {
    SelectionRestore restore(notebook);
    const auto wanted = parse_tab_id(tab_raw);
    switch_to_index(notebook, find_tab_index(*notebook, wanted));
    auto &session = notebook->tabs.active().session;
    const auto owner = session.cells.at(find_cell_index(session, cell_raw)).id;
    if (action == "save_cell_ui") notebook->tabs.save_cell_ui(owner, require_text(text_raw, "cell UI JSON"));
    else {
      const auto edits = sputnik::notebook::parse_project_input_edits(require_text(text_raw, "cell input batch JSON"));
      const bool changed = notebook->tabs.set_cell_inputs(owner, edits, !notebook->execution && !notebook->external);
      if (changed && notebook->external) {
        const auto first = find_cell_index(session, cell_raw);
        for (std::size_t i = first; i < session.cells.size(); ++i) if (session.cells[i].kind == "code") session.cells[i].dirty = true;
      }
      if (changed && notebook->execution && !notebook->external) notebook->execution->inputs_changed(notebook->tabs);
    }
    return;
  }
  if (action == "save_board") {
    const auto board = sputnik::notebook::parse_project_board(require_text(text_raw, "board JSON"));
    notebook->tabs.save_board(board);
    for (auto entry = notebook->periodic.begin(); entry != notebook->periodic.end();) {
      const auto prefix = board.id + ":";
      if (entry->first.compare(0, prefix.size(), prefix) == 0 &&
          [&] {
            bool exists = false;
            std::function<void(const std::vector<sputnik::notebook::ProjectComponent> &)> visit = [&](const auto &items) {
              for (const auto &component : items) {
                if ((component.kind == "periodic_work" || component.kind == "action") && entry->first == prefix + component.id) exists = true;
                if (component.panels) for (const auto &panel : *component.panels) visit(panel.components);
              }
            };
            visit(board.components); return !exists;
          }()) {
        if (notebook->execution && entry->second) notebook->execution->restart(*entry->second, "periodic:" + entry->first);
        entry = notebook->periodic.erase(entry);
      } else ++entry;
    }
    return;
  }
  if (action == "action_run" || action == "periodic_run" || action == "periodic_tick" || action == "periodic_dispose") {
    const auto board_id = require_text(text_raw, "board id");
    const auto component_id = require_text(cell_raw, "component id");
    const auto key = board_id + ":" + component_id;
    if (action == "periodic_dispose") {
      const auto found = notebook->periodic.find(key);
      if (found != notebook->periodic.end()) {
        if (notebook->execution && found->second) notebook->execution->restart(*found->second, "periodic:" + key);
        notebook->periodic.erase(found);
      }
      return;
    }
    const auto &project = notebook->tabs.project();
    const auto board = std::find_if(project.document.boards.begin(), project.document.boards.end(),
        [&](const auto &item) { return item.id == board_id; });
    if (board == project.document.boards.end()) throw std::runtime_error("Periodic Work board unavailable");
    const sputnik::notebook::ProjectComponent *component = nullptr;
    std::function<void(const std::vector<sputnik::notebook::ProjectComponent> &)> find = [&](const auto &items) {
      for (const auto &item : items) {
        if (item.id == component_id && item.kind == (action == "action_run" ? "action" : "periodic_work")) component = &item;
        if (item.panels) for (const auto &panel : *item.panels) find(panel.components);
      }
    };
    find(board->components);
    if (!component) throw std::runtime_error("Invocation component unavailable");
    auto settings = sputnik::notebook::PeriodicWorkSettings{};
    std::optional<sputnik::notebook::ProjectActionInvocation> invocation;
    if (action == "action_run") {
      invocation = sputnik::notebook::project_action_invocation(*component, notebook->tabs.inputs());
      settings.module_id = std::get<std::string>(sputnik::notebook::parse_project_input_value(component->extra.at("module_id")));
    } else settings = sputnik::notebook::project_periodic_work_settings(*component);
    const auto module = std::find_if(project.document.modules.begin(), project.document.modules.end(),
        [&](const auto &item) { return item.id == settings.module_id; });
    if (module == project.document.modules.end()) throw std::runtime_error("Periodic Work module unavailable: " + settings.module_id);
    for (std::size_t i = 0; i < notebook->tabs.tabs().size(); ++i)
      if (notebook->tabs.tabs()[i]->module && notebook->tabs.modified(i))
        throw std::runtime_error("Save modified module tabs before starting Periodic Work.");
    const auto source = invocation ? invocation->source : "import " + settings.module_id + "\n" + settings.module_id + "." + settings.function + "()\n";
    const auto bundled = load_project_bundled_sources(project);
    auto &tab = notebook->periodic[key];
    const auto same_sources = [](const auto &left, const auto &right) {
      if (left.size() != right.size()) return false;
      for (std::size_t i = 0; i < left.size(); ++i)
        if (left[i].id != right[i].id || left[i].path != right[i].path || left[i].source != right[i].source ||
            left[i].auto_import != right[i].auto_import) return false;
      return true;
    };
    const bool changed = tab && (tab->session.cells.empty() || tab->session.project_sheet_id != board->sheet ||
        tab->session.cells[0].source != source || !same_sources(tab->session.bundled_modules, bundled));
    if (changed && action == "periodic_tick")
      throw std::runtime_error("Modules changed. Start Periodic Work again to apply them.");
    if (changed) {
      if (notebook->execution) notebook->execution->restart(*tab, "periodic:" + key);
      tab.reset();
    }
    if (!tab) {
      auto candidate = std::make_unique<ProjectTab>();
      load_project_into_session(&candidate->session, project, board->sheet);
      Cell invocation;
      invocation.id = sputnik::notebook::allocate_cell_id(); invocation.source = source; invocation.watch = false;
      candidate->session.cells = {std::move(invocation)};
      tab = std::move(candidate);
    }
    tab->session.project_inputs = invocation ? invocation->inputs : std::make_shared<const sputnik::runtime::NotebookInputSnapshot>(notebook->tabs.inputs());
    if (notebook->execution) notebook->execution->run(notebook->tabs, *tab, "run", 0, "periodic:" + key, (action == "periodic_run" || action == "action_run"));
    else {
      auto token = std::make_shared<sputnik::runtime::RuntimeRunState>();
      std::exception_ptr failure;
      {
        sputnik::runtime::RuntimeRunCancellationScope scope(token);
        try { evaluate_from(&tab->session, 0, false, false, false); }
        catch (...) { failure = std::current_exception(); token->request_cancel(); }
        if (!tab->session.cells[0].ok) token->request_cancel();
      }
      token->close_root();
      while (!token->wait_for_idle(std::chrono::milliseconds(100))) {}
      if (failure) std::rethrow_exception(failure);
      const auto failures = token->unobserved_failures();
      if (!failures.empty()) {
        tab->session.cells[0].ok = false;
        tab->session.cells[0].error = failures[0].error_name + ": " + failures[0].message;
      }
    }
    if (tab->session.status.find("Cancelled") != std::string::npos ||
        tab->session.status.find("cancelled") != std::string::npos ||
        tab->session.status.find("unobserved child task failure") != std::string::npos) {
      tab->session.cells[0].ok = false;
      tab->session.cells[0].error = tab->session.status;
    }
    if (!tab->session.cells[0].ok && tab->session.cells[0].error.empty())
      tab->session.cells[0].error = tab->session.environment_error.empty() ? tab->session.status : tab->session.environment_error;
    return;
  }
  if (action == "component_data_edit") {
    notebook->tabs.edit_component_data(sputnik::notebook::parse_project_component_data_edit(require_text(text_raw, "component data edit JSON"))); return;
  }
  if (action == "restore_inputs") {
    notebook->tabs.restore_inputs(sputnik::notebook::parse_project_input_edits(require_text(text_raw, "saved input JSON"))); return;
  }
  if (action == "audio_edit") {
    notebook->tabs.edit_audio(sputnik::notebook::parse_project_audio_edit(require_text(text_raw, "audio edit JSON"))); return;
  }
  if (action == "image_edit") {
    notebook->tabs.edit_images(sputnik::notebook::parse_project_image_edit(require_text(text_raw, "image edit JSON")));
    return;
  }
  if (action == "image_select") {
    const auto target = parse_tab_id(tab_raw);
    if (target.module) throw std::runtime_error("image selection requires a sheet");
    const auto value = sputnik::notebook::parse_project_input_value(require_text(text_raw, "image index"));
    if (!std::holds_alternative<std::int64_t>(value) || std::get<std::int64_t>(value) < 0) throw std::runtime_error("invalid image index");
    notebook->tabs.select_image(target.id, require_text(cell_raw, "image channel"), std::get<std::int64_t>(value));
    return;
  }
  if (action == "new_input") {
    notebook->tabs.create_input(sputnik::notebook::parse_project_input(require_text(text_raw, "input JSON")));
    return;
  }
  if (action == "delete_input") {
    notebook->tabs.delete_input(require_text(cell_raw, "input id"));
    return;
  }

  if (action == "new_sheet") {
    const auto &sheets = notebook->tabs.project().document.sheets;
    std::uint64_t number = sheets.size();
    for (const auto &sheet : sheets) {
      const std::string prefix = "Sheet ";
      if (sheet.title.compare(0, prefix.size(), prefix) != 0) continue;
      const auto suffix = sheet.title.substr(prefix.size());
      std::uint64_t value = 0;
      const auto parsed = std::from_chars(suffix.data(), suffix.data() + suffix.size(), value);
      if (parsed.ec == std::errc{} && parsed.ptr == suffix.data() + suffix.size() && value < INT64_MAX)
        number = std::max(number, value);
    }
    notebook->tabs.create_sheet(require_text(text_raw, "text"), "Sheet " + std::to_string(number + 1));
    return;
  }
  if (action == "new_module") {
    notebook->tabs.create_module(require_text(text_raw, "text"));
    return;
  }
  if (action == "save_all") {
    SelectionRestore restore(notebook);
    const std::size_t original = notebook->tabs.selected();
    const std::size_t count = notebook->tabs.tabs().size();
    for (std::size_t offset = 0; offset < count; ++offset) {
      const std::size_t index = (original + offset) % count;
      if (!notebook->tabs.modified(index))
        continue;
      switch_to_index(notebook, index);
      notebook->tabs.save_active();
    }
    return;
  }

  const ParsedTabId target = parse_tab_id(tab_raw);
  const std::size_t tab_index = find_tab_index(*notebook, target);
  ProjectTab &tab = *notebook->tabs.tabs()[tab_index];
  Session &session = tab.session;

  if (action == "set_cell_id") {
    const auto index = find_cell_index(session, cell_raw);
    require_sheet_cell_editable(tab, session.cells[index], action);
    const auto text = require_text(text_raw, "Hard ID");
    std::uint64_t replacement = 0;
    const auto parsed = std::from_chars(text.data(), text.data() + text.size(), replacement);
    if (text.empty() || parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size())
      throw std::invalid_argument("Hard ID must be an integer from 1 to 18446744073709551614.");
    notebook->tabs.set_cell_id(session.cells[index].id, replacement);
    return;
  }

  if (action == "worker_environment") {
    if (!notebook->execution) throw std::runtime_error("Worker settings require isolated execution.");
    notebook->execution->configure_environment(tab, text_raw ? text_raw : "");
    return;
  }

  if (action == "worker_grants") {
    if (!notebook->execution) throw std::runtime_error("Worker settings require isolated execution.");
    notebook->execution->configure_grants(tab, text_raw ? text_raw : "");
    return;
  }

  if (action == "trust_native") {
    if (!notebook->execution) throw std::runtime_error("Native package execution requires an isolated worker.");
    notebook->execution->native_trusted = true;
    return;
  }

  if (notebook->execution && (action == "run" || action == "run_all" || action == "apply" || action == "restart_worker" || action == "watch_run")) {
    if (action == "restart_worker") { notebook->execution->restart(tab); return; }
    const auto index = action == "run" ? find_cell_index(session, cell_raw) : 0;
    if (action == "run" && session.cells[index].kind != "code")
      throw std::invalid_argument("Run applies only to code cells");
    notebook->execution->run(notebook->tabs, tab, action == "watch_run" ? "watch" : action, index);
    return;
  }

  if (action == "select") {
    const std::optional<std::size_t> selected_cell =
        cell_raw == nullptr ? std::nullopt
                            : std::optional<std::size_t>(
                                  find_cell_index(session, cell_raw));
    switch_to_index(notebook, tab_index);
    if (selected_cell.has_value())
      session.selected = *selected_cell;
    return;
  }

  if (action == "add_cell" || action == "add_text") {
    if (tab.module.has_value())
      throw std::invalid_argument("module editor has one source buffer");
    std::size_t insert_at = 0U;
    if (session.cells.empty()) {
      if (cell_raw != nullptr && cell_raw[0] != '\0')
        throw std::invalid_argument("empty sheet has no cell anchor");
    } else {
      if (cell_raw == nullptr || cell_raw[0] == '\0')
        throw std::invalid_argument("add_cell requires an after-cell ID");
      insert_at = find_cell_index(session, cell_raw) + 1U;
    }
    Cell added;
    added.id = sputnik::notebook::allocate_cell_id();
    if (action == "add_text") {
      added.kind = "text";
      added.watch = false;
      added.dirty = false;
      added.result.clear();
    }
    session.cells.insert(session.cells.begin() +
                             static_cast<std::ptrdiff_t>(insert_at),
                         std::move(added));
    session.selected = insert_at;
    session.document_dirty = true;
    if (action == "add_cell")
      clear_errors_from(&session, 0U);
    session.status = action == "add_text" ? "new text block" : "new cell";
    return;
  }

  if (action == "source" || action == "rich_source" || action == "watch" || action == "run" ||
      action == "delete_cell" || action == "move_up" ||
      action == "move_down") {
    const std::size_t cell_index = find_cell_index(session, cell_raw);
    Cell &cell = session.cells[cell_index];
    if (action == "rich_source") {
      if (tab.module.has_value() || cell.kind != "text")
        throw std::invalid_argument("rich_source requires a text block");
      auto content = sputnik::notebook::parse_project_text_content(require_text(text_raw, "text"));
      validate_editable_source(content.source, "text block");
      // Publish plain source and its matching attribute ranges together.
      cell.source.swap(content.source);
      cell.formatting.swap(content.formatting);
      session.document_dirty = true;
      session.status = "text block edited";
      return;
    }
    if (action == "source") {
      if (cell.kind == "text")
        throw std::invalid_argument("text blocks require a rich_source payload");
      const std::string source = require_text(text_raw, "text");
      validate_editable_source(source, "source edit");
      if (tab.module.has_value()) {
        if (session.cells.size() != 1U)
          throw std::runtime_error("module editor must contain one source cell");
        mark_source_edit(&session, cell_index, source);
      } else {
        require_sheet_cell_editable(tab, cell, action);
        mark_source_edit(&session, cell_index, source);
      }
      return;
    }
    if (action == "watch") {
      require_sheet_cell_editable(tab, cell, action);
      if (cell.kind != "code")
        throw std::invalid_argument("Watch applies only to code cells");
      const std::string setting = require_text(text_raw, "text");
      if (setting != "on" && setting != "off")
        throw std::invalid_argument("watch text must be on or off");
      cell.watch = setting == "on";
      session.document_dirty = true;
      session.status = cell.watch ? "object.watch enabled"
                                  : "object.watch disabled";
      return;
    }
    if (action == "run") {
      if (cell.kind != "code")
        throw std::invalid_argument("Run applies only to code cells");
      struct SelectedCellRestore {
        Session &session;
        std::size_t selected;
        ~SelectedCellRestore() { session.selected = selected; }
      } restore{session, session.selected};
      session.selected = cell_index;
      evaluate_from_with_progress(&session, cell_index, false, false, {});
      return;
    }
    if (action == "delete_cell") {
      require_sheet_cell_editable(tab, cell, action);
      const std::size_t code_count = static_cast<std::size_t>(std::count_if(
          session.cells.begin(), session.cells.end(),
          [](const Cell &candidate) { return candidate.kind == "code"; }));
      const bool removed_code = cell.kind == "code";
      if (removed_code && code_count == 1U) {
        Cell replacement;
        replacement.id = sputnik::notebook::allocate_cell_id();
        session.cells[cell_index] = std::move(replacement);
        session.selected = cell_index;
      } else {
        session.cells.erase(session.cells.begin() +
                            static_cast<std::ptrdiff_t>(cell_index));
        if (session.selected > cell_index)
          --session.selected;
        else if (session.selected == cell_index)
          session.selected = session.cells.empty() ? 0U : std::min(cell_index, session.cells.size() - 1U);
      }
      session.document_dirty = true;
      if (removed_code)
        clear_errors_from(&session, 0U);
      session.status = "cell deleted";
      return;
    }
    if (action == "move_up" || action == "move_down") {
      move_cell(&session, cell_index, action == "move_up");
      return;
    }
  }

  if (action == "run_all") {
    if (cell_raw != nullptr)
      (void)find_cell_index(session, cell_raw);
    evaluate_from_with_progress(&session, 0U, true, false, {});
    return;
  }
  if (action == "apply") {
    if (target.module)
      throw std::invalid_argument("Apply requires a sheet tab");
    if (cell_raw != nullptr)
      (void)find_cell_index(session, cell_raw);
    SelectionRestore restore(notebook);
    switch_to_index(notebook, tab_index);
    (void)notebook->tabs.apply_active(false, false, {});
    return;
  }
  if (action == "save") {
    if (cell_raw != nullptr)
      (void)find_cell_index(session, cell_raw);
    SelectionRestore restore(notebook);
    switch_to_index(notebook, tab_index);
    notebook->tabs.save_active();
    return;
  }
  if (action == "auto_import") {
    if (!target.module)
      throw std::invalid_argument("auto_import requires a module tab");
    const std::string setting = require_text(text_raw, "text");
    if (setting != "on" && setting != "off")
      throw std::invalid_argument("auto_import text must be on or off");
    SelectionRestore restore(notebook);
    switch_to_index(notebook, tab_index);
    (void)notebook->tabs.set_auto_import(target.id, setting == "on");
    return;
  }
  throw std::invalid_argument("unknown notebook action: " + action);
}

void report_current_exception(char **error) noexcept {
  try {
    throw;
  } catch (const std::exception &exception) {
    set_error(error, exception.what());
  } catch (...) {
    set_error(error, "unknown native notebook error");
  }
}

} // namespace

extern "C" {

SputnikNotebook *sputnik_notebook_open(const char *path, int create,
                                  const char *title, char **error) {
  if (error != nullptr)
    *error = nullptr;
  try {
    sputnik::notebook::register_builtin_renderers();
    if (path == nullptr || path[0] == '\0')
      throw std::invalid_argument("project path is required");
    sputnik::notebook::LoadedProject project;
    if (create != 0) {
      std::string project_title = title == nullptr ? "Sputnik Notebook" : title;
      if (project_title.empty())
        project_title = "Sputnik Notebook";
      auto document = sputnik::notebook::make_project_document(std::move(project_title));
      document.sheets.front().title = "Sheet 1";
      project = sputnik::notebook::create_project(path, document);
    } else {
      project = sputnik::notebook::load_project(path);
    }
    auto notebook = std::make_unique<SputnikNotebook>(std::move(project));
    validate_project_sources(*notebook);
    return notebook.release();
  } catch (...) {
    report_current_exception(error);
    return nullptr;
  }
}

void sputnik_notebook_destroy(SputnikNotebook *notebook) {
  try {
    delete notebook;
  } catch (...) {
  }
}

void sputnik_notebook_string_free(char *value) {
  try {
    std::free(value);
  } catch (...) {
  }
}

char *sputnik_notebook_normalize_grants(const char *text, char **error) {
  if (error) *error = nullptr;
  try {
    return copy_c_string(sputnik::notebook::worker::grants_text(
        sputnik::notebook::worker::parse_grants(text ? text : "")));
  } catch (...) { report_current_exception(error); return nullptr; }
}

char *sputnik_notebook_config_json(const char *text, int pretty, char **error) {
  if (error) *error = nullptr;
  try {
    return copy_c_string(sputnik::notebook::project_config_json(text ? text : "", pretty != 0));
  } catch (...) { report_current_exception(error); return nullptr; }
}

char *sputnik_notebook_config_document(const char *text, const char *format, int pretty, char **error) {
  if (error) *error = nullptr;
  try {
    return copy_c_string(sputnik::notebook::project_config_document(text ? text : "", format ? format : "json", pretty != 0));
  } catch (...) { report_current_exception(error); return nullptr; }
}

SputnikNotebookControl *sputnik_notebook_enable_worker(SputnikNotebook *notebook, const char *executable, char **error) {
  if (error) *error = nullptr;
  try {
    if (!notebook || notebook->commands_started || notebook->execution)
      throw std::runtime_error("Worker preview must be configured once immediately after open.");
    const auto path = require_text(executable, "worker executable");
    if (path.empty() || path.front() != '/') throw std::runtime_error("Worker executable must be an absolute path.");
    auto execution = std::make_unique<NotebookExecution>(path);
    auto control = std::make_unique<SputnikNotebookControl>(SputnikNotebookControl{execution->control});
    notebook->execution = std::move(execution);
    return control.release();
  } catch (...) { report_current_exception(error); return nullptr; }
}
void sputnik_notebook_control_destroy(SputnikNotebookControl *control) { delete control; }
int sputnik_notebook_control_phase(SputnikNotebookControl *control) {
  return control ? control->value->phase() : 0;
}
int sputnik_notebook_control_stop(SputnikNotebookControl *control, int force) {
  try { return control && control->value->stop(force != 0) ? 1 : 0; }
  catch (...) { return 0; }
}
void sputnik_notebook_control_prepare(SputnikNotebookControl *control) {
  if (control) control->value->begin();
}
void sputnik_notebook_control_finish(SputnikNotebookControl *control) {
  if (control) control->value->finish();
}

static char *presentation_live_json(const sputnik::notebook::worker::Presentation *value, const std::string &owner = {}) {
    std::string json = "{\"tab\":";
    append_json_string(&json, owner);
    json += ",\"executing_cell\":";
    append_json_string(&json, value->executing_cell ? std::to_string(value->executing_cell) : "");
    json += ",\"telemetry_updated\":"; append_bool(&json, value->telemetry_updated);
    json += ",\"telemetry\":"; append_telemetry(&json, value->telemetry);
    json += ",\"cells\":[";
    for (std::size_t i = 0; i < value->cells.size(); ++i) {
      if (i) json += ',';
      const auto &cell = value->cells[i];
      json += "{\"id\":"; append_json_string(&json, std::to_string(cell.id));
      json += ",\"output_updated\":"; append_bool(&json, cell.output_updated);
      json += ",\"output\":"; append_output(&json, cell.output);
      json += ",\"progress_updated\":"; append_bool(&json, cell.progress_updated);
      json += ",\"displays_updated\":"; append_bool(&json, cell.displays_updated);
      json += ",\"charts_updated\":"; append_bool(&json, cell.charts_updated);
      json += ",\"images_updated\":"; append_bool(&json, cell.images_updated);
      json += ",\"charts_reset\":"; append_bool(&json, cell.charts_reset);
      json += ",\"progress\":"; append_progress(&json, cell.progress);
      json += ",\"displays\":"; append_displays(&json, cell.displays);
      json += ",\"charts\":"; append_chart_series(&json, cell.charts);
      json += ",\"images\":"; append_image_series(&json, cell.images);
      json += ",\"audio\":"; append_audio_streams(&json, cell.audio);
      json += ",\"audio_controls\":"; append_audio_controls(&json, cell.audio_controls);
      json += ",\"audio_controls_updated\":"; append_bool(&json, cell.audio_controls_updated);
      json += ",\"audio_updated\":"; append_bool(&json, cell.audio_updated);
      json += ",\"audio_reset\":"; append_bool(&json, cell.audio_reset);
      json += ",\"elapsed_ms\":" + (cell.elapsed_ms ? std::to_string(*cell.elapsed_ms) : "null");
      json += ",\"timing_running\":"; append_bool(&json, cell.timing_running);
      json += ",\"stopwatches_updated\":"; append_bool(&json, cell.stopwatches_updated);
      json += ",\"stopwatches\":[";
      for (std::size_t j = 0; j < cell.stopwatches.size(); ++j) {
        if (j) json += ',';
        const auto &timer = cell.stopwatches[j];
        json += "{\"id\":"; append_json_string(&json, timer.id);
        json += ",\"elapsed_ms\":" + std::to_string(timer.elapsed_ms) + ",\"done\":";
        append_bool(&json, timer.done); json += '}';
      }
      json += ']';
      json += '}';
    }
    json += "]}";
    return copy_c_string(json);
}

char *sputnik_notebook_control_live(SputnikNotebookControl *control) {
  try {
    if (!control) return nullptr;
    std::string owner;
    const auto value = control->value->take_live(&owner);
    return value ? presentation_live_json(value.get(), owner) : nullptr;
  } catch (...) { return nullptr; }
}

char *sputnik_notebook_worker_pending(SputnikNotebook *notebook, char **error) {
  if (error) *error = nullptr;
  try {
    if (!notebook || !notebook->execution || notebook->external) return nullptr;
    const auto owner = notebook->execution->pending(notebook->tabs);
    return owner.empty() ? nullptr : copy_c_string(owner);
  } catch (...) { report_current_exception(error); return nullptr; }
}

int sputnik_notebook_external(SputnikNotebook *notebook, int enabled, char **error) {
  if (error) *error = nullptr;
  try {
    if (!notebook) throw std::invalid_argument("notebook handle is null");
    if (enabled || notebook->external != (enabled != 0))
      for (const auto &tab : notebook->tabs.tabs()) if (!tab->module) {
        for (auto &cell : tab->session.cells) if (cell.kind == "code") cell.dirty = true;
      }
    notebook->external = enabled != 0;
    return 1;
  } catch (...) { report_current_exception(error); return 0; }
}

char *sputnik_notebook_export(SputnikNotebook *notebook, char **error) {
  if (error) *error = nullptr;
  try {
    if (!notebook) throw std::invalid_argument("notebook handle is null");
    auto project = notebook->tabs.project();
    for (const auto &tab : notebook->tabs.tabs()) if (!tab->module)
      project.document = project_document_from_session(tab->session, project);
    std::string json = "{\"document\":";
    const auto serialized = sputnik::notebook::serialize_project_document(project.document);
    const auto saved = sputnik::notebook::serialize_project_document(sputnik::notebook::parse_project_document(project.baseline));
    // Preserve the original JSON bytes when no document fields changed. Only
    // an edited sheet needs a new serialization; unknown numeric fields retain
    // their exact spelling in both cases.
    append_json_string(&json, serialized == saved ? project.baseline : serialized);
    json += ",\"modules\":{";
    bool first = true;
    for (const auto &tab : notebook->tabs.tabs()) if (tab->module) {
      if (!first) json += ',';
      first = false;
      append_json_string(&json, tab->module->path);
      json += ':';
      append_json_string(&json, tab->session.cells.at(0).source);
    }
    return copy_c_string(json + "}}");
  } catch (...) { report_current_exception(error); return nullptr; }
}

char *sputnik_notebook_disk_export(SputnikNotebook *notebook, char **error) {
  if (error) *error = nullptr;
  try {
    if (!notebook) throw std::invalid_argument("notebook handle is null");
    SputnikNotebook disk(sputnik::notebook::load_project(notebook->tabs.project().directory));
    return sputnik_notebook_export(&disk, error);
  } catch (...) { report_current_exception(error); return nullptr; }
}

int sputnik_notebook_restore_document(SputnikNotebook *notebook, const char *document, char **error) {
  if (error) *error = nullptr;
  try {
    if (!notebook || !notebook->external) throw std::runtime_error("remote backend is not selected");
    const auto restored = sputnik::notebook::parse_project_document(require_text(document, "restored document"));
    std::vector<std::pair<Session *, std::vector<Cell>>> prepared;
    for (const auto &tab : notebook->tabs.tabs()) if (!tab->module) {
      const auto sheet = std::find_if(restored.sheets.begin(), restored.sheets.end(), [&](const auto &s) { return s.id == tab->session.project_sheet_id; });
      if (sheet == restored.sheets.end()) throw std::runtime_error("local notebook structure changed; download a server copy");
      std::vector<Cell> cells;
      for (const auto &saved : sheet->cells) {
        const auto original = std::find_if(tab->session.cells.begin(), tab->session.cells.end(), [&](const auto &c) { return c.id == saved.id; });
        Cell cell = original == tab->session.cells.end() ? Cell{} : *original;
        cell.id = saved.id; cell.kind = saved.kind; cell.source = saved.source;
        cell.watch = saved.mode == sputnik::notebook::CellMode::Watch; cell.formatting = saved.formatting;
        cell.cursor = cell.source.size(); cell.dirty = cell.kind == "code";
        sputnik::notebook::reserve_cell_id(cell.id);
        cells.push_back(std::move(cell));
      }
      prepared.emplace_back(&tab->session, std::move(cells));
    }
    for (auto &entry : prepared) {
      entry.first->cells.swap(entry.second); entry.first->selected = 0;
      entry.first->document_dirty = true;
    }
    return 1;
  } catch (...) { report_current_exception(error); return 0; }
}

static sputnik::notebook::worker::Presentation remote_presentation(const unsigned char *bytes, size_t size) {
  if (!bytes || size > sputnik::notebook::worker::kMaxPresentationBytes)
    throw std::invalid_argument("invalid remote presentation size");
  auto result = sputnik::notebook::worker::decode_presentation(std::string(reinterpret_cast<const char *>(bytes), size));
  std::set<sputnik::notebook::CellId> ids;
  for (const auto &cell : result.cells)
    if (!ids.insert(cell.id).second) throw std::runtime_error("duplicate remote presentation cell");
  return result;
}

char *sputnik_notebook_remote_live(const unsigned char *bytes, size_t size, char **error) {
  if (error) *error = nullptr;
  try { const auto value = remote_presentation(bytes, size); return presentation_live_json(&value); }
  catch (...) { report_current_exception(error); return nullptr; }
}

int sputnik_notebook_remote_result(SputnikNotebook *notebook, const char *sheet,
    const char *document, const unsigned char *bytes, size_t size, int stale, char **error) {
  if (error) *error = nullptr;
  try {
    if (!notebook || !notebook->external) throw std::runtime_error("remote backend is not selected");
    const auto id = require_text(sheet, "remote sheet");
    const auto executed = sputnik::notebook::parse_project_document(require_text(document, "execution document"));
    const auto origin = std::find_if(executed.sheets.begin(), executed.sheets.end(), [&](const auto &s) { return s.id == id; });
    if (origin == executed.sheets.end()) throw std::runtime_error("remote execution sheet is missing");
    const auto presentation = remote_presentation(bytes, size);
    if (presentation.cells.size() != origin->cells.size()) throw std::runtime_error("remote sheet shape mismatch");
    for (size_t i = 0; i < presentation.cells.size(); ++i)
      if (presentation.cells[i].id != origin->cells[i].id) throw std::runtime_error("remote cell identity mismatch");
    const auto target = std::find_if(notebook->tabs.tabs().begin(), notebook->tabs.tabs().end(),
        [&](const auto &t) { return !t->module && t->session.project_sheet_id == id; });
    if (target == notebook->tabs.tabs().end()) return 1; // A removed owner is never resurrected.
    auto &session = (*target)->session;
    auto cells = session.cells;
    for (auto &cell : cells) {
      const auto value = std::find_if(presentation.cells.begin(), presentation.cells.end(), [&](const auto &c) { return c.id == cell.id; });
      if (value == presentation.cells.end()) continue;
      const auto index = static_cast<size_t>(value - presentation.cells.begin());
      cell.dirty = value->dirty || stale || cell.source != origin->cells[index].source;
      cell.ok = value->ok; cell.result = value->result; cell.error = value->error;
      cell.result_format = value->result_format; cell.locals = value->locals;
      cell.output_events = value->output; cell.displays = value->displays;
      cell.progress = value->progress; cell.charts = value->charts; cell.images = value->images; cell.audio = value->audio; cell.audio_controls = value->audio_controls;
      cell.elapsed_ms = value->elapsed_ms; cell.stopwatches = value->stopwatches;
      cell.error_ranges = value->error_ranges; cell.errors = value->errors; cell.selected_error = 0;
      cell.watch_epoch = value->watch_epoch; cell.watch_event_count = value->watch_event_count;
    }
    session.run_telemetry = presentation.telemetry;
    session.cells.swap(cells);
    session.status = presentation.status;
    session.environment_error = presentation.environment_error;
    session.environment_output = presentation.environment_output;
    session.environment_stale = presentation.environment_stale || stale;
    return 1;
  } catch (...) { report_current_exception(error); return 0; }
}

char *sputnik_notebook_snapshot(SputnikNotebook *notebook, char **error) {
  if (error != nullptr)
    *error = nullptr;
  try {
    if (notebook == nullptr)
      throw std::invalid_argument("notebook handle is null");
    return copy_c_string(snapshot_json(*notebook));
  } catch (...) {
    report_current_exception(error);
    return nullptr;
  }
}

int sputnik_notebook_command(SputnikNotebook *notebook, const char *action,
                           const char *tab, const char *cell,
                           const char *text, char **error) {
  if (error != nullptr)
    *error = nullptr;
  try {
    command_impl(notebook, action, tab, cell, text);
    return 1;
  } catch (...) {
    report_current_exception(error);
    return 0;
  }
}

int sputnik_notebook_activity_descriptor(SputnikNotebook *notebook,
                                        char **error) {
  if (error != nullptr)
    *error = nullptr;
  try {
    if (notebook == nullptr)
      throw std::invalid_argument("notebook handle is null");
    return notebook->tabs.activity_waiter().poll_descriptor();
  } catch (...) {
    report_current_exception(error);
    return -1;
  }
}

int sputnik_notebook_pump(SputnikNotebook *notebook, int *next_delay_ms,
                        char **error) {
  if (error != nullptr)
    *error = nullptr;
  if (next_delay_ms != nullptr)
    *next_delay_ms = -1;
  try {
    if (notebook == nullptr)
      throw std::invalid_argument("notebook handle is null");

    if (notebook->execution || notebook->external) return 1; // No hidden local evaluation.
    const SessionActivityResult hints =
        notebook->tabs.activity_waiter().wait(std::chrono::milliseconds(0));
    if (hints.shutdown)
      throw std::runtime_error("notebook activity mailbox is closed");
    if (hints.runtime_ready || hints.input_ready) {
      for (const auto &tab : notebook->tabs.tabs()) {
        const SessionActivityResult local =
            tab->activity.wait(std::chrono::milliseconds(0));
        if (local.runtime_ready)
          tab->runtime_dispatch.notify_runtime();
      }
    }

    const std::size_t count = notebook->tabs.tabs().size();
    const auto now = RuntimePumpDispatch::Clock::now();
    for (std::size_t offset = 0; offset < count; ++offset) {
      const std::size_t index = (notebook->runtime_cursor + offset) % count;
      ProjectTab &tab = *notebook->tabs.tabs()[index];
      if (!tab.runtime_dispatch.due(now))
        continue;
      const RuntimeEventPumpResult result =
          pump_runtime_events_detailed(&tab.session, false, {});
      tab.runtime_dispatch.complete(result, RuntimePumpDispatch::Clock::now());
      notebook->runtime_cursor = (index + 1U) % count;
      break;
    }

    std::optional<std::chrono::milliseconds> next;
    const auto next_now = RuntimePumpDispatch::Clock::now();
    for (const auto &tab : notebook->tabs.tabs()) {
      const auto delay = tab->runtime_dispatch.wait_timeout(next_now);
      if (delay.has_value() && (!next.has_value() || *delay < *next))
        next = delay;
    }
    if (next_delay_ms != nullptr && next.has_value()) {
      const auto bounded = std::min<std::int64_t>(
          std::max<std::int64_t>(0, next->count()),
          std::numeric_limits<int>::max());
      *next_delay_ms = static_cast<int>(bounded);
    }
    return 1;
  } catch (...) {
    report_current_exception(error);
    return 0;
  }
}

} // extern "C"
