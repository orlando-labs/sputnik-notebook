# DataTableView and notebook.show

`DataTableView` is an ordinary Sputnik object in the `notebook.ui` helper package.
It defines a tabular representation and text exports. `notebook.show` publishes
that object to the active cell, using the same display lifecycle as a plot.
Neither constructing a view nor exporting text requires an active notebook.

```sputnik
from notebook.ui import DataTableView

view = DataTableView(rows, columns: ["Наряд", "Заказ", "Вес"])
notebook.show(view, id: "orders", caption: "Наряды")

csv = view.to_csv()
markdown = view.to_markdown()
42
```

The sheet displays the table plus the ordinary result `42`. A Data Table board
component selects the publishing cell and, optionally, the `orders` channel.
An empty channel selector shows all tables published by that cell. This channel
is a name authored in code, independent of an internal cell ID. The designer
offers the published captions as shortcuts to their channel bindings.

Link `sputnik-lang/packages/notebook_ui` as a local dependency. The repository
sample `tools/notebook-macos/Samples/Data Tables.sputnikbook` already does so.
The [SQLite example](notebook-sqlite-example.md) publishes database pages through
`DataTableView` while returning a scalar row count from the same cell.

## Data and columns

`DataTableView(data, columns: null)` accepts an Array or Tuple containing:

- Maps: infer the union of keys in encounter order. Explicit Str/Symbol columns
  select keys and control column order. Missing keys are displayed as null.
- Arrays/Tuples: explicit columns label their positions; otherwise use
  `Column 1`, `Column 2`, etc. Short rows are padded with null. Rows wider than
  explicit columns raise `ArgumentError`.
- Scalars: one column, named `Value` unless an explicit label is supplied.

Mixed row shapes and duplicate column names are rejected. Empty data can retain
its schema with `DataTableView([], columns: ["Заказ", "Вес"])`.
The view keeps its source data; a later show/export observes current values.
Each publication copies an immutable snapshot, so later source mutations cannot
change already-published data. Numbers, booleans, strings and null stay typed;
nested values use a bounded textual preview in the UI.

## Publication and live updates

Use the existing options `caption:`, `order:`, `id:`, `live:` and `throttle_ms:`.
Calls without an ID add independent tables. Repeating an ID replaces that
display in the current run. Supplying an ID enables live updates by default;
`live: false` stages the table until successful completion instead. `order:`
orders a cell's display batch; the sheet renders figures and tables in their
respective output sections.

```sputnik
from notebook.ui import DataTableView

notebook.show(DataTableView(batch, columns: [:step, :loss]),
              id: "training", caption: "Training metrics", throttle_ms: 200)
# Explicit terminal update, even if the previous frame was recent:
notebook.show(DataTableView(final_rows, columns: [:step, :loss]), id: "training")
```

Throttling skips conversion and publication before preparing a snapshot. A zero
throttle accepts a final frame. Showing requires an active synchronous notebook
cell; ordinary nested helper calls work, detached tasks cannot publish into that
cell. Rerunning replaces the cell's batch. Failed execution retains its previous
successful committed tables, using the same rules as figures.

The snapshot is limited to 4,096 rows, 32 columns and 1 MiB. Too many declared
columns raise an error; row/data limits retain a bounded snapshot marked as
truncated. Tables share the existing 64-display / 64 MiB cell budget. No database
query or filesystem write is implied by displaying a view.

## CSV and Markdown

`view.to_csv()` and `view.to_markdown()` return text for all data supplied to the
view, in declared column order. They do not write files. CSV quotes every field,
doubles embedded quotes and uses CRLF records. Markdown escapes pipes,
backslashes and HTML, and represents cell newlines with `<br>`.

Every native table has a **⋯** menu, on both sheets and boards:

- **Copy CSV** / **Save CSV…**
- **Copy Markdown** / **Save Markdown…** (`.md`)
- **Copy selected row** and **Reset sorting**

Menu exports use the currently filtered and sorted rows retained by the UI.
They cannot export rows that were excluded by SQL pagination or snapshot limits.
The table indicates when its snapshot is truncated. Numeric sorting preserves
large integer precision; text exports retain Int64 values without Double casts.

The existing **View table** action in Result Inspector remains available for
array results. Old board tables bound to cell results continue to work. Explicit
publication uses display output and does not depend on Result Inspector.

Worker protocol 14 / presentation v11 add stable display channel identity and
the inert `application/vnd.sputnik.table+json` payload. No VM object or database
handle crosses the worker boundary. Remote execution uses the same transport.

## Verification

`make test-notebook-table test-notebook-table-ui` checks independent scalar
results, multiple ordered tables, static/live channel replacement, immutable
snapshots, empty schemas, invalid shapes, failed-run retention, exact integers,
CSV/Markdown parity, filtered exports and board/sheet rendering in both themes.
The worker protocol tests additionally round-trip named table displays and
reject invalid raster dimensions and oversized table payloads.
