#ifndef SPUTNIK_NOTEBOOK_BRIDGE_H
#define SPUTNIK_NOTEBOOK_BRIDGE_H

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

// Opt-in preview, configured once immediately after open, before any command.
// Never silently falls back to executing code in the host. Returned control
// owns an independent lifetime; its methods alone are safe on another thread.
SputnikNotebookControl *sputnik_notebook_enable_worker(SputnikNotebook *, const char *executable, char **error);
void sputnik_notebook_control_destroy(SputnikNotebookControl *);
int sputnik_notebook_control_phase(SputnikNotebookControl *); // 0 idle; 1..5 prepare/run/drain/stop/terminate
int sputnik_notebook_control_stop(SputnikNotebookControl *, int force);
// Thread-safe, immutable latest live output; null means no update. Free with string_free.
char *sputnik_notebook_control_live(SputnikNotebookControl *);

// Stable IDs: tab is "sheet:<id>" or "module:<id>"; cell is a decimal string.
// Actions: select, source, watch (text "on"/"off"), run, run_all, apply,
// add_cell/add_text (after cell), rich_source (JSON source+formatting payload),
// delete_cell, move_up, move_down, save, save_all,
// new_sheet (text = ID), new_module (text = ID), auto_import (text on/off).
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
