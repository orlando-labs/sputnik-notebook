package notebook.remote.host

export Worker, pid, environment, environment_candidates, remove_environment_candidate, environment_log

# Application binding to Sputnik Notebook's existing supervisor/codec.
# Run policy, storage, receipts and network protocols live in Sputnik modules.
native class Worker from "notebook.remote.Worker" owned:
  def init(executable as Str, directory as Str, grants as List, environment_directory as Str) from "nb_remote_worker_new" blocking
  def send(kind as Int, fields as List) -> Int from "nb_remote_worker_send" blocking
  def poll() from "nb_remote_worker_poll" blocking
  def stop!(request as Int, force as Bool) -> Bool from "nb_remote_worker_stop"
  def close!() from "nb_remote_worker_close" blocking
  def pid() -> Int from "nb_remote_worker_pid"
  def destroy!() from "nb_remote_worker_free"

native def pid() -> Int from "nb_remote_pid"
native def environment(directory as Str) -> Str from "nb_remote_environment" blocking

native def environment_candidates(directory as Str) -> Str from "nb_remote_environment_candidates" blocking
native def remove_environment_candidate(directory as Str, id as Str, identity as Str) -> Bool from "nb_remote_remove_environment_candidate" blocking
native def environment_log(directory as Str) -> Str from "nb_remote_environment_log" blocking
