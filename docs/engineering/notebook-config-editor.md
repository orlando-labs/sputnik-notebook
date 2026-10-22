# Config Editor: JSON, YAML and TOML

Config Editor is a compact, text-only component on boards, beside code cells,
and in Parameter Form. It displays the format, byte/line counts and **Edit…**.
The source always opens in a large modal with its own scrollable viewport;
a long document never expands the component. Config settings offer **Format**
(JSON, YAML or TOML); there is no value-type or generic input-style selector.
Changing the format does not convert or rewrite the source.

Add **Config Editor** from the board palette or a cell's **Components…** menu.
Cell creation adds a local text parameter with `{}` as its saved default.
Choose the format in the inspector, then edit the local default or create a
project config. A new TOML config starts empty. Existing String fields in
Parameter Form can select **Config Editor** as their control.

Try `tools/notebook-macos/Samples/Config Editor.sputnikbook`. It includes all
three formats, independent project/cell scopes, Watch and Manual consumers,
and serialization examples.

## Read and serialize in code

The existing `notebook.input` and `notebook.cell_input` APIs return the accepted
source text. These helpers parse an accepted config into ordinary Map/List and
scalar values while recording the same input dependency:

```sputnik
config = notebook.config("yaml", format: :yaml)
local = notebook.cell_config("training", format: :json)
rate = config[:optimizer][:rate]

# Parse a text value directly, without an input binding:
settings = notebook.parse_config("epochs = 10", format: :toml)

# Serialize data into a new document (comments/layout are not data):
yaml_text = notebook.serialize_config(settings, format: :yaml)
toml_text = notebook.serialize_config(settings, format: :toml)
json_text = notebook.serialize_config(settings, format: :json)
```

The format keyword defaults to `:json`; pass `:yaml` or `:toml` explicitly.
JSON can also use `Json.parse`, `Json.pretty_generate` and `Json.save_to_file`.
For YAML/TOML, `fs.write_text(path, text)` writes the serialized source under the
ordinary execution grants. These notebook helpers use the same config codecs
as host validation; the older standalone `Yaml` library has its own subset.
TOML serialization requires a mapping at the root and rejects `null`, which
TOML cannot represent. TOML dates/times are exposed as their ISO text, without
host timezone conversion; serializing those Str values writes TOML strings.

## Modal editing and lifetime

The modal provides syntax highlighting, native selection/Undo, indentation,
validation diagnostics, Import and Export. Config editors never substitute
Greek letter names. The JSON-only Format action preserves numeric lexemes,
including exact Int64 values. YAML/TOML retain comments and layout verbatim;
no formatting action silently strips them.

Typing, Import and Format change only the modal draft. **Cancel** discards it.
**Reset** restores the text from when the modal opened. For standalone board/cell
inputs, **Apply** publishes the accepted snapshot and closes after success.
Failed Apply keeps the modal open with its draft and diagnostic. In Parameter
Form and default-value editors, **Use Config** stages the text in the parent;
the form's atomic Apply or Save Components publishes it later.

Validation also runs in shared input transactions before publication, including
direct commands and remote cell input requests. Rejected batches change no
values. Watch readers update in graph order; Manual readers become stale.
Opening, editing and importing never execute code.

Accepted values retain the existing input lifetime: session state is separate
from saved defaults, and reopening restores defaults. Local defaults are edited
through Components. Project defaults are defined on creation; Export retains a
changed config as a separate file. Import/export use client files and transport
text rather than file paths. Remote cell inputs keep their server-owned
lifetime and require an updated worker/core. Project-wide remote inputs retain
their existing restrictions.

## Formats and limits

Sources are UTF-8, at most 64 KiB, with no literal NUL. Import/export and Apply
preserve the exact source; export adds no trailing newline. Duplicate keys,
invalid syntax and unsupported format settings are rejected.

- JSON accepts a complete value, Int64 integers and finite Float numbers, with
  nesting up to 64. JSON Format is explicit and may normalize object-key escapes.
- YAML uses LibYAML's event parser and the YAML 1.2 core scalar schema. Block/flow
  collections, quoted strings, literal/folded text and nonrecursive aliases are
  supported. Config mapping keys are strings. Multiple documents, merge keys,
  recursive aliases, custom tags and nonfinite/out-of-range numbers are rejected.
- TOML uses toml++ 3.4.0 and TOML 1.0 syntax, including dotted keys, table arrays,
  inline tables, multiline strings and dates/times. Numbers must fit Int64 or a
  finite Float.

YAML/TOML parsing is bounded to depth 64, 16,384 expanded values and 512 KiB of
expanded JSON. New serialized documents must fit the same 64 KiB source limit.
The macOS bundle includes LibYAML and its license. Linux builds require
`libyaml-dev`; toml++ is vendored with its MIT license in `sputnik-lang/third_party`.

## Storage and verification

The component reuses `kind: "input"`, `control.style: "json"` and a String input
snapshot. `config_format` selects its parser; absence means JSON for existing
books. No runtime objects or new input wire types cross the worker boundary.

```json
{"kind":"input","id":"config","title":"Training config","input":"training",
 "control":{"style":"json","config_format":"yaml"}}
```

`make test-notebook-config` checks all three formats, exact files, atomic Apply,
Watch/Manual and scope isolation in both local and worker modes, plus compact
components and modal Cancel/Reset/Undo/Apply/form staging. Previews are written
to `build/config-editor/`. In `sputnik-lang`, `make test-config-document` covers
syntax, scalar types, aliases, invalid input, depth limits and serialization.
