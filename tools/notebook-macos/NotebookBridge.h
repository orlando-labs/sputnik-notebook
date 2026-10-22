#ifndef SPUTNIK_NOTEBOOK_BRIDGE_H
#define SPUTNIK_NOTEBOOK_BRIDGE_H
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SputnikNotebook SputnikNotebook;
typedef struct SputnikNotebookControl SputnikNotebookControl;

// All calls for a handle, including destruction, belong to ONE serial owner
// queue. Returned strings are UTF-8, caller-owned, and freed with string_free.
// Opening/creating, editing and saving never execute Sputnik source.
SputnikNotebook *sputnik_notebook_open(const char *path, int create,
                                  const char *title, char **error);
void sputnik_notebook_destroy(SputnikNotebook *notebook);
void sputnik_notebook_string_free(char *value);
char *sputnik_notebook_snapshot(SputnikNotebook *notebook, char **error);
int sputnik_notebook_external(SputnikNotebook *, int enabled, char **error);
char *sputnik_notebook_export(SputnikNotebook *, char **error);
char *sputnik_notebook_disk_export(SputnikNotebook *, char **error);
int sputnik_notebook_restore_document(SputnikNotebook *, const char *document, char **error);
int sputnik_notebook_remote_result(SputnikNotebook *, const char *sheet,
    const char *document, const unsigned char *bytes, size_t size, int stale, char **error);
char *sputnik_notebook_remote_live(const unsigned char *bytes, size_t size, char **error);

// GUI execution backend, configured once immediately after open, before any command.
// Never silently falls back to executing code in the host. Returned control
// owns an independent lifetime; its methods alone are safe on another thread.
SputnikNotebookControl *sputnik_notebook_enable_worker(SputnikNotebook *, const char *executable, char **error);
void sputnik_notebook_control_destroy(SputnikNotebookControl *);
int sputnik_notebook_control_phase(SputnikNotebookControl *); // 0 idle; 1..5 prepare/run/drain/stop/terminate
int sputnik_notebook_control_stop(SputnikNotebookControl *, int force);
void sputnik_notebook_control_prepare(SputnikNotebookControl *);
void sputnik_notebook_control_finish(SputnikNotebookControl *);
// Thread-safe, immutable latest live output; null means no update. Free with string_free.
char *sputnik_notebook_control_live(SputnikNotebookControl *);
// Owner-queue only. Inert readiness check for existing worker watch mailboxes.
// Returns a tab ID, or null when idle. Never evaluates source.
char *sputnik_notebook_worker_pending(SputnikNotebook *, char **error);
// Stateless policy validation shared with the worker. Returns canonical grants,
// one per line, or null with a diagnostic. Does not authorize execution.
char *sputnik_notebook_normalize_grants(const char *text, char **error);
// Stateless Config Editor validation/formatting; never creates a runtime.
char *sputnik_notebook_config_json(const char *text, int pretty, char **error);
char *sputnik_notebook_config_document(const char *text, const char *format, int pretty, char **error);

// Stable IDs: tab is "sheet:<id>" or "module:<id>"; cell is a decimal string.
// Actions: select, source, watch (text "on"/"off"), run, run_all, apply,
// add_cell/add_text (after cell), rich_source (JSON source+formatting payload),
// delete_cell, move_up, move_down, save, save_all,
// new_sheet (text = ID), new_module (text = ID), auto_import (text on/off).
// retain_cell_results (text on/off) saves this book's result-retention option
// independently from unsaved source buffers; it never executes user code.
// worker_grants: text = newline-separated cap[=target]; explicitly resets the
// selected worker. Host policy is persisted by the app, outside the notebook.
// set_input (cell = input ID, text = scalar JSON), set_inputs (text = JSON map
// of input IDs to scalar JSON strings): validate/publish one immutable batch.
// save_cell_ui: cell = code cell ID, text = v4 cell_ui configuration JSON.
// set_cell_inputs: cell = owner cell ID, text = local input batch JSON strings.
// action_run: cell = Action component ID, text = board ID. Frozen arguments
// are evaluated in a separate invocation runtime and exposed in periodic_results.
// periodic_run/periodic_tick/periodic_dispose: cell = service component ID,
// text = board ID. Run explicitly permits fresh saved module sources; Tick
// refuses source changes. Results are immutable text in periodic_results.
// A failed operation never throws across the C boundary. Runtime diagnostics
// are available in the next snapshot even when an evaluation faults.
int sputnik_notebook_command(SputnikNotebook *notebook, const char *action,
                           const char *tab, const char *cell,
                           const char *text, char **error);

// Borrowed event descriptor. Do not read/close it. Pump consumes the mailbox
// on the owner queue and processes bounded runtime work across the tabs.
// next_delay_ms = -1 means idle, otherwise schedule one bounded retry.
int sputnik_notebook_activity_descriptor(SputnikNotebook *notebook, char **error);
int sputnik_notebook_pump(SputnikNotebook *notebook, int *next_delay_ms,
                        char **error);

#ifdef __cplusplus
}
#endif
#endif
