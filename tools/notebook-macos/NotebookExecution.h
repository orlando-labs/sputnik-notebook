#pragma once
#include "tools/isputnik/tabs.h"
#include "tools/notebook-worker/process.h"
#include "tools/notebook-worker/presentation.h"
#include <map>
#include <memory>
#include <mutex>

// Independent lifetime, no Session/UI pointers. Only this small control object
// is shared with the main thread while the bridge owner waits for IPC.
class NotebookExecutionControl {
public:
  int phase() const;
  bool stop(bool force);
  void begin(std::string owner = {});
  void bind(std::shared_ptr<sputnik::notebook::worker::Process> process);
  void running(sputnik::notebook::worker::RequestId request);
  void draining();
  bool forced() const;
  bool commit();
  void finish();
  void publish_live(sputnik::notebook::worker::Presentation);
  std::shared_ptr<const sputnik::notebook::worker::Presentation> take_live(std::string *owner = nullptr);
private:
  mutable std::mutex mutex_;
  // 0 idle, 1 preparing, 2 running, 3 draining, 4 stopping, 5 terminating.
  int phase_ = 0;
  bool stop_ = false, force_ = false;
  std::shared_ptr<sputnik::notebook::worker::Process> process_;
  sputnik::notebook::worker::RequestId request_;
  std::uint64_t generation_ = 0;
  std::optional<sputnik::notebook::worker::Presentation> live_;
  std::string owner_;
};

// Owner-queue only. One persistent worker per sheet; host Sessions remain
// source/presentation containers and never construct a local VM in this mode.
class NotebookExecution {
public:
  explicit NotebookExecution(std::string executable) : executable_(std::move(executable)) {}
  std::shared_ptr<NotebookExecutionControl> control = std::make_shared<NotebookExecutionControl>();
  bool run(ProjectTabs &, ProjectTab &, const std::string &action, std::size_t index,
           const std::string &runtime_key = {}, bool recover = false);
  void restart(ProjectTab &, const std::string &runtime_key = {});
  void configure_grants(ProjectTab &, const std::string &text);
  void configure_environment(ProjectTab &, const std::string &directory);
  void inputs_changed(ProjectTabs &);
  std::string pending(ProjectTabs &);
  bool native_trusted = false;
private:
  struct Sheet {
    std::shared_ptr<sputnik::notebook::worker::Process> process;
    bool interrupted = false;
    std::string owner;
  };
  std::string executable_;
  std::map<std::string, Sheet> sheets_;
  std::map<std::string, std::vector<std::string>> grants_;
  std::map<std::string, std::string> environment_directories_;
  std::size_t watch_cursor_ = 0;
};
