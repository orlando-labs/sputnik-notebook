package results

from notebook.core.common import decode, terminal?
from notebook.core.host import presentation_text_snapshot

export RichResults

# Table values leave Sputnik as typed text so int64 never passes through a
# JavaScript Number. Snapshot limits mirror NotebookTableSnapshot in Swift.
def table_value(value):
  kind = if value == null then "null" else if Bool === value then "boolean" else if Int === value then "integer" else if Float === value then "number" else if Str === value then "text" else "unsupported"
  raise ArgumentError("invalid table value") if kind == "unsupported"
  text = if value == null then "" else value.to_str
  raise ArgumentError("oversized table value") if text.bytes.count > 24576
  {kind: kind, text: text}

def table_snapshot(text):
  return null if text == ""
  raise ArgumentError("oversized table") if text.bytes.count > 1048576
  table = decode(text)
  columns = table[:columns]
  rows = table[:rows]
  raise ArgumentError("invalid table shape") unless columns.count > 0 and columns.count <= 32 and rows.count <= 4096
  raise ArgumentError("invalid row count") unless Int === table[:total_rows] and Bool === table[:truncated] and table[:total_rows] >= rows.count and (table[:truncated] or table[:total_rows] == rows.count)
  column_ids = columns.map: $it[:id]
  row_ids = rows.map: $it[:id]
  raise ArgumentError("duplicate table identities") unless column_ids.uniq.count == columns.count and row_ids.uniq.count == rows.count
  public_columns = columns.map |column|:
    raise ArgumentError("invalid table column") unless Str === column[:id] and Str === column[:title] and column[:title].bytes.count <= 1024 and ["null", "text", "integer", "number", "boolean", "mixed"].include?(column[:type])
    {id: column[:id], title: column[:title], type: column[:type]}
  public_rows = rows.map |row|:
    raise ArgumentError("invalid table row") unless Str === row[:id] and row[:values].count == columns.count
    {id: row[:id], values: row[:values].map: table_value($it)}
  {columns: public_columns, rows: public_rows, total_rows: table[:total_rows].to_str, truncated: table[:truncated]}

class RichResults:
  def init(@notebooks)

  def figure(value):
    base = {id: value[:id], mime: value[:mime], caption: value[:caption], width: value[:width], height: value[:height]}
    if value[:mime] == "application/vnd.sputnik.table+json":
      base.merge({table: table_snapshot(value[:data])})
    else:
      base.merge({data: value[:data], plot_scene: value[:plot_scene]})

  def cell_snapshot(cell):
    displays = cell[:displays].map: figure($it)
    images = cell[:images].map |series|:
      {id: series[:id], caption: series[:caption], images: series[:images].map: figure($it)}
    {id: cell[:id], source_revision: cell[:source_revision], dirty: cell[:dirty], table: table_snapshot(cell[:table_json]),
      displays: displays, images: images, audio: cell[:audio], audio_controls: cell[:audio_controls], audio_limited: cell[:audio_limited], unsupported: cell[:unsupported],
      progress: cell[:progress], stopwatches: cell[:stopwatches], charts: cell[:charts],
      elapsed_ms: cell[:elapsed_ms], timing_running: cell[:timing_running], metrics: cell[:metrics], text_values: cell[:text_values], diagnostics: cell[:diagnostics], diagnostics_truncated: cell[:diagnostics_truncated],
      result_format: cell[:result_format]}

  def task_snapshot(value, sources):
    return null unless value
    tasks = value[:tasks].map |task|:
      source = sources.find: $it[:kind] == "code" and $it[:id] == task[:cell]
      {id: task[:id], parent: task[:parent], state: task[:state], error: task[:error], elapsed_ms: task[:elapsed_ms],
        cell: if source then task[:cell] else null, line: if source then task[:line] else null}
    {revision: value[:revision], active: value[:active], total: value[:total], dropped: value[:dropped],
      sampled_ms: value[:sampled_ms], cpu_percent: value[:cpu_percent], resident_bytes: value[:resident_bytes], tasks: tasks}

  def board_bindings(components, sources, bindings, depth = 0):
    return if depth > 8
    components.each |component|:
      name = component[?:binding]
      if component[:kind] == "metric" and Str === name and name != "":
        cell = component[?:cell]
        id = if cell then cell.to_str else ""
        bindings.push!([id, name]) if sources.any?: $it[:id] == id
      (component[?:panels] or []).each |panel|:
        board_bindings(panel[:components], sources, bindings, depth + 1)

  def board_texts(components, texts, depth = 0):
    return if depth > 8
    components.each |component|:
      if component[:kind] == "rich_text" and component[?:text_content]:
        texts.push!(["", "board", component[:text_content][:source]])
      elif component[:kind] == "text" and Str === component[?:binding] and component[?:cell]:
        texts.push!([component[:cell].to_str, "binding", component[:binding]])
      (component[?:panels] or []).each |panel|: board_texts(panel[:components], texts, depth + 1)

  def read(record, sources = [], boards = []):
    try:
      bytes = @notebooks.presentation_bytes(record, live: not terminal?(record[:state]))
      return {cells: [], error: "", text_limited: false, task_telemetry: null} unless bytes
      bindings = []
      sources.each |cell|:
        ui = cell[?:cell_ui]
        if ui:
          ((ui[?:pre] or []) + (ui[?:post] or [])).each |component|:
            name = component[?:binding]
            bindings.push!([cell[:id], name]) if component[:kind] == "metric" and Str === name and name != ""
      boards.each |board|: board_bindings(board[:components], sources, bindings)
      texts = sources.map |cell|: [cell[:id], cell[:kind], (if cell[:kind] == "text" then cell[:source] else "")]
      boards.each |board|: board_texts(board[:components], texts)
      value = decode(presentation_text_snapshot(bytes, bindings, texts))
      cells = value[:cells].map: cell_snapshot($it)
      raise ArgumentError("rich result exceeds size limit") if Json.generate(cells).bytes.count > 33554432
      {cells: cells, error: "", text_limited: value[:text_limited], task_telemetry: task_snapshot(value[:task_telemetry], sources)}
    rescue Exception:
      # Preserve text/error results if media is missing, malformed or too large.
      {cells: [], error: "Rich results could not be loaded or exceed the supported size. Reload to retry.", text_limited: false, task_telemetry: null}
