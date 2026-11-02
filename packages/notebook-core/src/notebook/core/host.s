package notebook.core.host

export Worker, pid, environment, environment_candidates, remove_environment_candidate, environment_log, presentation_snapshot, presentation_bound_snapshot, presentation_text_snapshot, book_entries, book_read, book_pack, book_text, book_base64?

# Application binding to Sputnik Notebook's existing supervisor/codec.
# Run policy, storage, receipts and network protocols live in Sputnik modules.
native class Worker from "notebook.core.Worker" owned:
  def init(executable as Str, directory as Str, grants as List, environment_directory as Str) from "nb_core_worker_new" blocking
  def send(kind as Int, fields as List) -> Int from "nb_core_worker_send" blocking
  def poll() from "nb_core_worker_poll" blocking
  def activity?() -> Bool from "nb_core_worker_activity" blocking
  def stop!(request as Int, force as Bool) -> Bool from "nb_core_worker_stop"
  def close!() from "nb_core_worker_close" blocking
  def pid() -> Int from "nb_core_worker_pid"
  def destroy!() from "nb_core_worker_free"

native def pid() -> Int from "nb_core_pid"
native def environment(directory as Str) -> Str from "nb_core_environment" blocking

native def environment_candidates(directory as Str) -> Str from "nb_core_environment_candidates" blocking
native def remove_environment_candidate(directory as Str, id as Str, identity as Str) -> Bool from "nb_core_remove_environment_candidate" blocking
native def environment_log(directory as Str) -> Str from "nb_core_environment_log" blocking

# Inert rich result DTO, decoded by the same validated codec as the desktop.
# No paths, source documents, VM values or device handles. Audio publications and
# ordered player requests are inert metadata/bytes with an aggregate bound.
# Bound snapshots expose
# only numeric module-cell values requested by the immutable execution document.
# Text snapshots additionally project declared prose bindings and bounded source
# diagnostics; both are inert, with no browser-selected locals query.
native def presentation_snapshot(bytes as Bytes) -> Str from "nb_core_presentation_snapshot" blocking
native def presentation_bound_snapshot(bytes as Bytes, bindings as List) -> Str from "nb_core_presentation_bound_snapshot" blocking
native def presentation_text_snapshot(bytes as Bytes, bindings as List, sources as List) -> Str from "nb_core_presentation_text_snapshot" blocking

# ZIP transport around the normal .sputnikbook directory, without extraction.
native def book_entries(entries as List) -> List from "nb_core_book_entries" blocking
native def book_read(bytes as Bytes) -> List from "nb_core_book_read" blocking
native def book_pack(entries as List) -> Bytes from "nb_core_book_pack" blocking
# Bounded UTF-8 classification is CPU-only and never waits for I/O.
native def book_text(bytes as Bytes) from "nb_core_book_text"

native def book_base64?(text as Str) -> Bool from "nb_core_book_base64"

# Archive accounting and filesystem reserve; filesystem traversal never follows symlinks.
native def storage_bytes(path as Str) -> Int from "nb_core_storage_bytes"
native def storage_available(path as Str) -> Int from "nb_core_storage_available"
export storage_bytes, storage_available

native class ServiceSignals from "notebook.core.ServiceSignals" owned:
  def init() from "nb_core_service_signals_new"
  def requested?() -> Bool from "nb_core_service_signals_requested"
  def destroy!() from "nb_core_service_signals_free"

native class ServiceProcess from "notebook.core.ServiceProcess" owned:
  def init(executable as Str, arguments as List) from "nb_core_service_process_new" blocking
  def pid() -> Int from "nb_core_service_process_pid"
  def running?() -> Bool from "nb_core_service_process_running"
  def close!() from "nb_core_service_process_close" blocking
  def destroy!() from "nb_core_service_process_free"

native def executable() -> Str from "nb_core_executable"
export ServiceSignals, ServiceProcess, executable

native def package_home() -> Str from "nb_core_package_home"
native def package_link(source as Str, home as Str, relative as Str) -> Bool from "nb_core_package_link" blocking
native def package_unlink(home as Str, relative as Str) -> Bool from "nb_core_package_unlink" blocking
native def package_reference?(path as Str) -> Bool from "nb_core_package_reference" blocking
export package_home, package_link, package_unlink, package_reference?
