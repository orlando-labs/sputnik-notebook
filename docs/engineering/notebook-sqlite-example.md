# Data Table with a real SQLite database

The `Строки` example links the local `sqlite3` package and reads an
external database. It never copies the database into the notebook. SQL runs in
the isolated worker; `notebook.show(DataTableView(rows))` publishes a typed table
independently from the cell's final scalar result.
No subprocess or CSV/JSON conversion is used to fetch the displayed data.

From `sputnik-notebook`, create and open the example:

```sh
python3 tools/notebook-macos/make-sqlite-sample.py build/SQLite-Rows.sputnikbook \
  --database '../../лекционный материал/строки.sqlite3'
open -a "$PWD/build/Sputnik Notebook.app" "$PWD/build/SQLite-Rows.sputnikbook"
```

The page cell uses the helper package explicitly:

```sputnik
from notebook.ui import DataTableView

table_view = DataTableView(page_data[:rows], columns: page_data[:columns])
notebook.show(table_view, id: "rows", caption: "Строки из SQLite")
loaded_rows
```

The Data Table component binds to this cell and its `rows` channel. CSV and
Markdown can be exported with `table_view.to_csv()` / `to_markdown()` or the
table's **⋯** menu. See the [DataTableView contract](notebook-data-table-view.md).

The database must have `Строка 1`, `Строка 2`, `Строка 3` and the columns used
in [queries.s](../../tools/notebook-sqlite/queries.s). This example targets that
dataset; it is not a general database schema browser.

On the **Обзор базы** board, select a table, optionally enter part of a work-order
number or order code, choose a page size and page, then **Apply → Run Sheet**.
The sheet uses Manual cells so changing parameters does not start SQL silently.
**Choose file…** can point to another database with the same schema. The absolute
database path is stored as an editable input; moving the database requires
changing this reference. The package dependency uses a relative directory link.

The board contains:

- A File Input referencing the external SQLite file.
- A Parameter Form for server-side selection and pagination (25–500 rows).
- Execution Controls with Run, Stop and Force Stop.
- Metrics for the complete match count, fetched rows and page count.
- A Data Table for the fetched page.
- Database table counts and a top-15 order summary aggregated in SQLite over
  **all matching rows**, independent of the current page.

The source module opens `sqlite3.open(path, mode: :readonly)`, binds search,
`LIMIT` and `OFFSET` values, and closes the connection before publishing results.
The count and page are queried within one deferred read transaction. An excessive
page number is clamped to the last page. Identifiers are selected from a fixed
allowlist and quoted. `instr` treats apostrophes, `%` and `_` in search literally.
Rows use SQLite `rowid` for deterministic ordering without exposing it as a
display column. Separate summary queries take their own read snapshots; a live
database can change between the page and the summary.

Data Table's **Filter rows**, header sorting and CSV export operate on the
**fetched page**. They do not rewrite SQL, paginate the database or export every
matching row. Page counters above the table describe the database query; the
table's own row count describes its received snapshot. Markdown menu export
has the same page scope as CSV. Data Table currently
retains at most 4,096 rows, 32 columns and 1 MiB of presentation data. SQL limits
the example to 500 rows and eight columns before reaching that boundary.

The supplied database stores dates as `ДД.ММ.ГГГГ` text. Sorting those strings
does not produce chronological order; a date query needs explicit normalization.
Searches and grouped summaries scan data in SQLite; no indexes are added to the
user's database. Large offsets are suitable for this demonstration, while larger
production datasets should use indexed predicates and keyset pagination.

## Native package preparation

The generator compiles the package's vendored SQLite and C leaves into a small
shared library using the local C compiler. It stores source snapshots, a build
manifest, the library and hashes in `sqlite3/out/notebook/<fingerprint>/`.
Existing matching generations are verified and reused. Source changes produce a
new generation; an existing notebook is never overwritten. The notebook records
the manifest, library and library SHA-256 for the worker's normal native package
loader. This requires the sibling source checkouts and a C compiler, without
network downloads or a separate SQLite installation.

Opening the notebook is inert. The app's existing **Trust and Run** prompt
appears on first execution because the package loads native code. No manual
Worker Settings grants are needed for this local example.

## Integration verification

```sh
make -j2 build/notebook_macos_sqlite_tests
build/notebook_macos_sqlite_tests \
  --worker "$PWD/build/sputnik-notebook-worker" --trust-native \
  --project "$PWD/build/SQLite-Rows.sputnikbook" \
  --output "$PWD/build/sqlite-example"
```

The test runs the real Swift model and worker, compares fetched pages/counts
against independent read-only `/usr/bin/sqlite3` queries, checks all three tables,
literal search, empty results, last-page clamping, manual invalidation and
document preservation, then renders the board in light and dark themes. The CLI
is only an independent test oracle; notebook execution uses `sqlite3`.
