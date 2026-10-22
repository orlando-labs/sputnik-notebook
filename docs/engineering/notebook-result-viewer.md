# Notebook result viewer

Cell results have a collapsed, selectable preview (600 characters / six lines),
an expandable native scrolling text view, and a copy action. Arrays, tuples,
sets and maps offer Inspect / Pretty representations. Pretty is generated from
the runtime value, not by attempting to parse an inspection string; quotes,
commas and braces inside strings are preserved.

Secondary actions live in the **…** menu at the upper-right corner: Inspect /
Pretty, Wrap lines, Find, and Copy. Wrap lines is enabled by default; disabling
it preserves line widths and enables horizontal scrolling in both the collapsed
preview and the expanded/search view. This per-result display choice survives
result updates and representation changes while the viewer remains mounted.
Search controls are shown only after Find is requested.
Expand / Collapse remains a lightweight inline action only when the collapsed
preview actually hides captured text. This includes the character/newline
budget and six-line wrapping at the current width, measured using the same
SwiftUI text layout as the preview. Resizing, changing representation, and
replacing a result recompute this condition. A runtime truncation flag alone
does not create an Expand button when all captured text is already visible.

Find performs literal substring search over the **entire captured representation**,
including text outside the collapsed preview. It highlights all non-overlapping
matches, emphasizes the active match, shows the count, and wraps next/previous
navigation. Enter moves forward. Matching ignores case unless Aa is selected.
Changing representation or result resets navigation. Selecting/copying text does
not execute code.

The runtime limits each representation while walking the value: 64 KiB of UTF-8,
4,096 visited values, and depth 16. Cycle references are marked. Extremely large
BigInts use a size summary rather than expensive decimal conversion. Truncation
is explicit in both metadata and UI; search/copy covers only captured text, not
omitted values. Expanding changes layout, not this safety budget. The underlying
Sputnik value remains unchanged. The same bounded formatter protects local-value
inspection; prose interpolation retains raw string contents rather than escapes.

Snapshots include immutable pretty text and independent truncation flags for
Inspect and Pretty. They cross worker protocol v9 / presentation v8 and the
JSON bridge. Failed or cleared evaluations cannot retain an old pretty string
alongside a new error result. No runtime Value or lazy callback reaches the UI.

## Retaining the previous run result

By default, the macOS model keeps one last successful result per cell in memory.
Editing source, starting another run, cancellation or a new error leaves that
snapshot available in the sheet and board Result Inspector. It is explicitly
labelled **PREVIOUS RUN RESULT**; a result rendered as a table has a **Result from
previous run** label. The same Inspect/Pretty, find, copy, wrapping and table
controls apply, using the original bounded result metadata. The latest error is
displayed separately. A new successful evaluation replaces the snapshot.

**Notebook Settings** (the gear beside Worker Settings) has **Keep results from
the previous run**. It is enabled by default; changing it saves the boolean
`retain_cell_results` in this book's `project.json`, independently from unsaved
cell/module sources. Disabling it immediately drops the retained snapshots and
hides stale results, while fresh results remain visible. It affects this book
only. Captured result values are never serialized into the project.

Opening another notebook or reopening this one clears the in-memory cache.
Restart Worker and applying worker grants clear the affected sheet's result
presentation, and inert snapshots cannot restore it. A new successful evaluation
is required. Remote clients also discard results from explicitly reset runtime
epochs, including after reconnecting; server execution history remains intact.
The remote registry exposes `reset_epochs` from durable reset receipts, so Force
Stop can retain a previous result until an explicit reset. Imported historical
results retain their run identity and cannot be relabelled current after a newer
run fails without publishing a presentation.

Checks: `make test-notebook-results`, worker round-trip/end-to-end tests, isputnik,
native bridge and model regressions. For an isolated visual fixture, run
`build/notebook_macos_result_tests --interactive`; this does not touch any project.
