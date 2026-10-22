#include "runtime/sputnik_ext.h"
#include "tools/notebook-worker/process.h"
#include "tools/notebook-worker/presentation.h"
#include <filesystem>
#include <fstream>
#include <sys/stat.h>
#include <cstring>
#include <memory>
#include <thread>
#include <unistd.h>
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
      out += "{\"id\":" + quote(e.id) + ",\"current\":" + std::to_string(e.current) +
          ",\"total\":" + std::to_string(e.total) + ",\"done\":" + (e.done ? "true" : "false") + '}';
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
  if (!sputnik_handle_ptr(cx, self, "notebook.remote.Worker", &ptr)) return nullptr;
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
extern "C" SputnikStatus nb_remote_worker_new(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
  try {
    if (argc != 4 || !sputnik_is_list(cx, args[2])) throw ProtocolError("Worker expects executable, working directory, grants and environment directory");
    std::vector<std::string> grants;
    for (size_t i = 0; i < sputnik_list_len(cx, args[2]); ++i) grants.push_back(str(cx, sputnik_list_at(cx, args[2], i)));
    auto w = std::make_unique<HostWorker>();
    w->process.start(str(cx, args[0]), str(cx, args[1]), grants, str(cx, args[3]));
    auto ready = w->process.receive(5s);
    if (!ready || ready->kind != Kind::Ready) throw ProtocolError("worker handshake timed out");
    *out = sputnik_make_handle(cx, "notebook.remote.Worker", w.get());
    if (!*out) return SPUTNIK_ERR;
    w.release(); return SPUTNIK_OK;
  } catch (const std::exception &e) { return sputnik_fault(cx, "IOError", e.what()); }
}
extern "C" SputnikStatus nb_remote_worker_send(SputnikCtx *cx, SputnikValue self, const SputnikValue *args, size_t argc, SputnikValue *out) {
  try {
    auto w = worker(cx, self); if (!w) return SPUTNIK_ERR;
    int64_t kind = 0;
    if (argc != 2 || !sputnik_as_int(cx, args[0], &kind) || !sputnik_is_list(cx, args[1])) throw ProtocolError("invalid worker command");
    if (kind != 2 && kind != 4 && kind != 14 && kind != static_cast<int64_t>(Kind::Inputs)) throw ProtocolError("unsupported remote worker command");
    std::vector<std::string> fields;
    for (size_t i = 0; i < sputnik_list_len(cx, args[1]); ++i) fields.push_back(str(cx, sputnik_list_at(cx, args[1], i)));
    w->request = w->process.send(static_cast<Kind>(kind), std::move(fields)).request;
    w->terminal.emplace(w->process.generation(), w->request); w->live.reset(); w->latest = {};
    *out = sputnik_make_int(cx, w->request); return SPUTNIK_OK;
  } catch (const std::exception &e) { return sputnik_fault(cx, "IOError", e.what()); }
}
extern "C" SputnikStatus nb_remote_worker_poll(SputnikCtx *cx, SputnikValue self, const SputnikValue *, size_t, SputnikValue *out) {
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
extern "C" SputnikStatus nb_remote_worker_stop(SputnikCtx *cx, SputnikValue self, const SputnikValue *args, size_t argc, SputnikValue *out) {
  auto w = worker(cx, self); if (!w) return SPUTNIK_ERR;
  int64_t request = 0; int force = 0;
  if (argc != 2 || !sputnik_as_int(cx, args[0], &request) || request < 0 || !sputnik_as_bool(cx, args[1], &force)) return sputnik_fault(cx, "TypeError", "invalid Stop");
  *out = sputnik_make_bool(cx, force ? w->process.request_force_stop(w->process.generation()) : w->process.request_stop({w->process.generation(), static_cast<std::uint64_t>(request)}));
  return SPUTNIK_OK;
}
extern "C" SputnikStatus nb_remote_worker_close(SputnikCtx *cx, SputnikValue self, const SputnikValue *, size_t, SputnikValue *out) {
  try {
    auto w = worker(cx, self); if (!w) return SPUTNIK_ERR;
    w->process.request_force_stop(w->process.generation());
    while (!w->process.poll_exit()) std::this_thread::sleep_for(10ms);
    *out = sputnik_make_null(cx); return SPUTNIK_OK;
  } catch (const std::exception &e) { return sputnik_fault(cx, "IOError", e.what()); }
}
extern "C" SputnikStatus nb_remote_worker_pid(SputnikCtx *cx, SputnikValue self, const SputnikValue *, size_t, SputnikValue *out) {
  auto w = worker(cx, self); if (!w) return SPUTNIK_ERR;
  *out = sputnik_make_int(cx, w->process.pid()); return SPUTNIK_OK;
}
extern "C" void nb_remote_worker_free(SputnikCtx *, void *ptr) { delete static_cast<HostWorker *>(ptr); }
extern "C" SputnikStatus nb_remote_pid(SputnikCtx *cx, const SputnikValue *, size_t, SputnikValue *out) {
  *out = sputnik_make_int(cx, ::getpid()); return SPUTNIK_OK;
}

extern "C" SputnikStatus nb_remote_environment(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
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
extern "C" SputnikStatus nb_remote_environment_candidates(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
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
extern "C" SputnikStatus nb_remote_remove_environment_candidate(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
  try {
    if (argc != 3) throw ProtocolError("expected projects directory, id and identity");
    const auto root = str(cx, args[0]), id = str(cx, args[1]), expected = str(cx, args[2]);
    const auto actual = project_identity(root, id);
    if (actual.empty() || actual != expected) { *out = sputnik_make_bool(cx, false); return SPUTNIK_OK; }
    std::filesystem::remove_all(std::filesystem::path(root) / id); // remove_all does not follow child symlinks.
    *out = sputnik_make_bool(cx, true); return SPUTNIK_OK;
  } catch (const std::exception &e) { return sputnik_fault(cx, "IOError", e.what()); }
}
extern "C" SputnikStatus nb_remote_environment_log(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
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
