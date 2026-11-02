#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "notebook/core/worker/process.h"
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <csignal>
#include <cstring>
#include <cstdlib>
#include <fcntl.h>
#include <fstream>
#include <limits>
#include <map>
#include <set>
#include <sstream>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#ifdef __APPLE__
#include <libproc.h>
#include <sys/proc.h>
#else
#include <dirent.h>
#endif
extern char **environ;

namespace sputnik::notebook::worker {
namespace {
std::atomic<std::uint64_t> generations{1};
struct LostChild : ProtocolError { using ProtocolError::ProtocolError; };
// Each worker starts a private OS session. system.command creates its own
// process groups, so killing only the worker's group would leave those alive.
// The unreaped session leader pins the session ID until cleanup is confirmed.
std::map<pid_t, pid_t> session_members(pid_t session) {
  std::map<pid_t, pid_t> members;
#ifdef __APPLE__
  int capacity = ::proc_listallpids(nullptr, 0) + 128;
  if (capacity <= 128) throw ProtocolError("cannot inspect worker process session");
  std::vector<pid_t> pids;
  int count;
  do {
    pids.resize(capacity);
    count = ::proc_listallpids(pids.data(), static_cast<int>(pids.size() * sizeof(pid_t)));
    if (count <= 0) throw ProtocolError("cannot inspect worker process session");
    capacity *= 2;
  } while (count >= static_cast<int>(pids.size()));
  for (int i = 0; i < count; ++i) {
    const auto pid = pids[i];
    if (pid <= 0 || ::getsid(pid) != session) continue;
    proc_bsdinfo info{};
    if (::proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info) &&
        info.pbi_status != SZOMB)
      members.emplace(pid, static_cast<pid_t>(info.pbi_pgid));
  }
#else
  std::unique_ptr<DIR, decltype(&::closedir)> directory(::opendir("/proc"), ::closedir);
  if (!directory) throw ProtocolError("cannot inspect worker process session");
  while (const auto *entry = ::readdir(directory.get())) {
    char *end = nullptr;
    const long pid = std::strtol(entry->d_name, &end, 10);
    if (!pid || *end) continue;
    std::ifstream input(std::string("/proc/") + entry->d_name + "/stat");
    std::string stat; std::getline(input, stat);
    const auto close = stat.rfind(')');
    if (close == std::string::npos) continue;
    std::istringstream fields(stat.substr(close + 1));
    char state; pid_t parent, group, sid;
    if (fields >> state >> parent >> group >> sid && sid == session && state != 'Z')
      members.emplace(static_cast<pid_t>(pid), group);
  }
#endif
  return members;
}
void signal_groups(const std::map<pid_t, pid_t> &members, pid_t session, int signal) {
  std::set<pid_t> groups;
  for (const auto &[pid, group] : members) if (group > 0 && group != session) groups.insert(group);
  for (const auto group : groups) {
    // Recheck membership before signalling a group from a process-list snapshot.
    // A vanished group is harmless; never signal a group in another session.
    const auto member = std::find_if(members.begin(), members.end(), [&](const auto &p) {
      return p.second == group && ::getsid(p.first) == session && ::getpgid(p.first) == group;
    });
    if (member != members.end()) ::kill(-group, signal);
  }
}
std::optional<int> reap_session(pid_t child) {
  siginfo_t info{};
  if (::waitid(P_PID, static_cast<id_t>(child), &info, WEXITED | WNOHANG | WNOWAIT) < 0) {
    if (errno == EINTR) return std::nullopt;
    if (errno == ECHILD) throw LostChild("notebook worker child ownership lost");
    throw ProtocolError("notebook worker waitid failed");
  }
  if (!info.si_pid) return std::nullopt;
  terminate_process_session(child);
  if (!session_members(child).empty()) return std::nullopt;
  int status;
  if (::waitpid(child, &status, WNOHANG) != child) throw ProtocolError("notebook worker waitpid failed");
  return status;
}
struct Fds {
  int values[2]{-1, -1};
  ~Fds() { for (int fd : values) if (fd >= 0) ::close(fd); }
  void make(int type) {
    if (::socketpair(AF_UNIX, type, 0, values) < 0) throw ProtocolError("worker socketpair failed");
    for (int &fd : values) {
      // Child dup destinations cannot alias either endpoint, even in a host
      // with hundreds of open descriptors. All originals are close-on-exec.
      const int moved = ::fcntl(fd, F_DUPFD_CLOEXEC, 200);
      if (moved < 0) throw ProtocolError("worker descriptor allocation failed");
      ::close(fd); fd = moved;
      configure_socket(fd);
    }
  }
};
} // namespace
void terminate_process_session(pid_t leader) {
  if (leader <= 0) return;
  const bool self = leader == ::getpid();
  if (!self) {
    // A host-wide SIGCHLD handler may have reaped our child. Validate ownership
    // before using its numeric PID as a session ID, including in the reaper.
    siginfo_t info{};
    int rc;
    do { rc = ::waitid(P_PID, static_cast<id_t>(leader), &info, WEXITED | WNOHANG | WNOWAIT); }
    while (rc < 0 && errno == EINTR);
    if (rc < 0) {
      if (errno == ECHILD) throw LostChild("notebook worker child ownership lost");
      throw ProtocolError("cannot confirm worker session ownership");
    }
  }
  // Stop the evaluator before discovering all of its command groups. Repeat
  // discovery after stopping them so descendants spawned during the first
  // scan are included too. The host never joins the worker's private session.
  if (!self) ::kill(-leader, SIGSTOP);
  std::map<pid_t, pid_t> members, previous;
  do {
    previous = std::move(members);
    members = session_members(leader);
    signal_groups(members, leader, SIGSTOP);
  } while (members != previous);
  signal_groups(members, leader, SIGKILL);
  ::kill(-leader, SIGKILL); // Session leader last, after its external groups.
}
Process::~Process() {
  try { request_force_stop(generation_); } catch (...) {}
  // A stuck OS process must not freeze UI teardown. Retain exact child
  // ownership in a reaper until waitpid confirms death, without retaining UI.
  try { (void)poll_exit(); } catch (...) { /* Keep ownership on transient inspection errors. */ }
  if (pid_ > 0) {
    const auto child = pid_;
    std::thread([child] {
      for (;;) {
        try {
          if (reap_session(child)) break;
          terminate_process_session(child);
        }
        catch (const LostChild &) { break; }
        catch (...) { /* Retain ownership and retry cleanup after a transient inspection error. */ }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
      }
    }).detach();
  }
  if (control_ >= 0) ::close(control_);
}
void Process::start(const std::string &executable, const std::string &working_directory,
                    const std::vector<std::string> &grants, const std::string &environment_directory) {
  std::lock_guard<std::mutex> lock(control_mutex_);
  if (pid_ > 0) throw ProtocolError("worker has not exited; confirm exit before restarting");
  if (executable.empty() || executable[0] != '/') throw ProtocolError("worker executable must be absolute");
  Fds data, control;
  data.make(SOCK_STREAM); control.make(SOCK_DGRAM);
  const int data_fd = data.values[0]; data.values[0] = -1;
  auto next_channel = std::make_unique<Channel>(data_fd);
  const auto next_generation = generations.fetch_add(1);
  if (!next_generation) throw ProtocolError("worker generation exhausted");
  std::string generation = std::to_string(next_generation);
  if (!working_directory.empty() && working_directory[0] != '/') throw ProtocolError("worker working directory must be absolute");
  std::vector<std::string> arguments{executable, "--notebook-worker", generation};
  if (!working_directory.empty()) { arguments.push_back("--working-directory"); arguments.push_back(working_directory); }
  environment_ = Environment::discover(environment_directory.empty() ? working_directory : environment_directory);
  if (!environment_.directory.empty()) {
    arguments.push_back("--environment-directory"); arguments.push_back(environment_.directory);
    arguments.push_back("--environment-fingerprint"); arguments.push_back(environment_.fingerprint);
  }
  std::size_t size = 0;
  if (grants.size() > 128) throw ProtocolError("too many worker grants");
  for (const auto &grant : grants) {
    size += grant.size() + 1;
    if (size > 32768 || grant.find_first_of("\n\r") != std::string::npos || grant.find('\0') != std::string::npos)
      throw ProtocolError("invalid worker grant argument");
    arguments.push_back("--grant"); arguments.push_back(grant);
  }
  std::vector<char *> args;
  for (auto &argument : arguments) args.push_back(argument.data());
  args.push_back(nullptr);
  posix_spawn_file_actions_t actions;
  if (posix_spawn_file_actions_init(&actions) != 0) throw ProtocolError("spawn actions init failed");
  posix_spawnattr_t attributes;
  if (posix_spawnattr_init(&attributes) != 0) {
    posix_spawn_file_actions_destroy(&actions);
    throw ProtocolError("spawn attributes init failed");
  }
  int rc = posix_spawn_file_actions_adddup2(&actions, data.values[1], kDataFd);
  if (!rc) rc = posix_spawn_file_actions_adddup2(&actions, control.values[1], kControlFd);
  if (!rc) rc = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
  if (!rc) rc = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
  if (!rc) rc = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSID);
  pid_t child = -1;
  if (!rc) rc = ::posix_spawn(&child, executable.c_str(), &actions, &attributes, args.data(), environ);
  posix_spawnattr_destroy(&attributes);
  posix_spawn_file_actions_destroy(&actions);
  if (rc) throw ProtocolError("start notebook worker: " + executable + ": " + std::strerror(rc));
  channel_ = std::move(next_channel);
  control_ = control.values[0]; control.values[0] = -1;
  pid_ = child; generation_ = next_generation;
  in_flight_ = 0; next_request_ = 1; exit_.reset();
  last_sent_.store(0);
}
RequestId Process::send(Kind kind, std::vector<std::string> fields) {
  if (!channel_ || exit_) throw ProtocolError("worker is not running");
  if (in_flight_) throw ProtocolError("worker request already in flight");
  if ((kind == Kind::Run || kind == Kind::Apply || kind == Kind::Watch || kind == Kind::Inputs) &&
      !environment_.directory.empty() &&
      Environment::discover(environment_.directory).fingerprint != environment_.fingerprint)
    throw ProtocolError("worker environment changed; Restart Worker before running cells");
  if (next_request_ == std::numeric_limits<std::uint64_t>::max()) throw ProtocolError("worker request id exhausted");
  const auto id = next_request_++;
  channel_->send({kind, generation_, id, std::move(fields)}, std::chrono::seconds(2));
  in_flight_ = id;
  last_sent_.store(id);
  return {generation_, id};
}
std::optional<Message> Process::receive(std::chrono::milliseconds timeout) {
  if (!channel_) throw ProtocolError("worker is not started");
  auto message = channel_->receive(timeout);
  if (message) {
    if (message->generation != generation_) throw ProtocolError("stale worker generation");
    if (message->kind == Kind::Ready) {
      if (message->request != 0) throw ProtocolError("invalid worker handshake");
    } else {
      if (!in_flight_ || message->request != in_flight_) throw ProtocolError("stale worker reply");
      if (message->kind == Kind::Result || message->kind == Kind::Error) in_flight_ = 0;
      else if (message->kind != Kind::Started && message->kind != Kind::Draining &&
               message->kind != Kind::SnapshotBegin && message->kind != Kind::SnapshotChunk &&
               message->kind != Kind::LiveBegin && message->kind != Kind::LiveChunk &&
               message->kind != Kind::LiveEnd)
        throw ProtocolError("unexpected worker reply");
    }
  }
  return message;
}
bool Process::request_stop(RequestId request) {
  std::lock_guard<std::mutex> lock(control_mutex_);
  if (pid_ <= 0 || !request.request || control_ < 0 ||
      request.generation != generation_ || request.request > last_sent_.load()) return false;
  const auto bytes = encode({Kind::Stop, generation_, request.request, {}});
#ifdef MSG_NOSIGNAL
  constexpr int flags = MSG_NOSIGNAL;
#else
  constexpr int flags = 0;
#endif
  return ::send(control_, bytes.data(), bytes.size(), flags) == static_cast<ssize_t>(bytes.size());
}
bool Process::request_force_stop(std::uint64_t expected_generation) {
  std::lock_guard<std::mutex> lock(control_mutex_);
  if (pid_ <= 0 || expected_generation != generation_) return false;
  terminate_process_session(pid_);
  return true;
}
std::optional<int> Process::poll_exit() {
  std::lock_guard<std::mutex> lock(control_mutex_);
  if (exit_ || pid_ <= 0) return exit_;
  try {
    const auto status = reap_session(pid_);
    if (!status) return std::nullopt;
    exit_ = *status; pid_ = -1;
    if (control_ >= 0) ::close(control_);
    control_ = -1;
  } catch (const LostChild &) {
    // Losing ownership is not proof of a successful stop. Invalidate the PID
    // before reporting the error so a later Force Stop cannot hit a reused PID.
    pid_ = -1;
    if (control_ >= 0) ::close(control_);
    control_ = -1;
    throw;
  }
  return exit_;
}
} // namespace sputnik::notebook::worker
