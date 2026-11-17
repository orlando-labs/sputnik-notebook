package notebook.core.package_components

export package_components, package_board

def relative_path?(name):
  return false unless Str === name and name.length > 0 and name.length <= 512 and not name.ends_with?("/") and not name.contains?("\\")
  return false if name.chars.any?: $it.bytes[0] == 0
  name.split("/").all? |part|:
    part != "" and part != "." and part != ".."

def member(directory, name, limit):
  return null unless relative_path?(name)
  path = directory
  for part in name.split("/"):
    path += "/" + part
    return null unless fs.exists?(path) and not fs.metadata(path).symlink?
  return null unless fs.metadata(path).file?
  inventory = directory + "/checksums.sha256"
  return null unless fs.exists?(inventory) and fs.metadata(inventory).file? and not fs.metadata(inventory).symlink?
  data = fs.read_text(path, limit: limit)
  checksum = Digest.sha256(data.bytes).hex + "  " + name
  return null unless fs.read_text(inventory, limit: 1048576).split("\n").include?(checksum)
  Json.parse(data)
rescue Exception:
  null

def identifier?(name):
  Str === name and name.length > 0 and name.length <= 128 and "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_".contains?(name[0]) and name.chars.all? |c|:
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789".contains?(c)

def title?(name): Str === name and name.length > 0 and name.length <= 128

def property?(value):
  return false unless Map === value and identifier?(value[?:id]) and title?(value[?:title])
  return false unless ["text", "integer", "toggle", "input", "module"].include?(value[?:kind])
  initial = value[?:initial]
  return false unless initial == null or (Str === initial and initial.length <= 8192)
  (value[?:minimum] == null or Int === value[:minimum]) and (value[?:maximum] == null or Int === value[:maximum])

def descriptor(directory):
  document = member(directory, "notebook/components.json", 131072)
  return [] unless Map === document and document[?:version] == 1
  components = document[?:components]
  return [] unless Array === components and components.count <= 64
  ids = []
  for component in components:
    return [] unless Map === component and identifier?(component[?:id]) and title?(component[?:title])
    return [] unless ["board", "service"].include?(component[?:kind]) and not ids.include?(component[:id])
    ids.push!(component[:id])
    properties = component[?:properties] or []
    return [] unless Array === properties and properties.count <= 32 and properties.all?: property?($it)
    property_ids = properties.map: $it[:id]
    return [] unless property_ids.uniq.count == properties.count
    return [] if component[:kind] == "board" and not relative_path?(component[?:board])
  components

def registry_reference?(name):
  return false unless Str === name and name.length > 0 and name.length <= 257 and not name.contains?("..") and not name.ends_with?("/")
  parts = name.split("/")
  parts.count <= 2 and parts.all? |part|:
    part.length > 0 and "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".contains?(part[0]) and part.chars.all? |c|:
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".contains?(c)

def public_component(value):
  properties = (value[?:properties] or []).map |property|:
    {id: property[:id], title: property[:title], kind: property[:kind], initial: property[?:initial], minimum: property[?:minimum], maximum: property[?:maximum]}
  detail = value[?:detail]
  {id: value[:id], kind: value[:kind], title: value[:title], detail: if Str === detail and detail.length <= 512 then detail else "", properties: properties}

def package_components(packages):
  installed = packages.filter: not $it[?:missing]
  names = installed.map: $it[:name]
  providers = []
  recommendations = []
  installed.each |item|:
    directory = item[:directory]
    components = descriptor(directory)
    existing = providers.any?: $it[:id] == item[:name]
    if not components.empty? and not existing:
      providers.push!({id: item[:name], name: item[:display_name], components: components.map: public_component($it)})
    manifest = member(directory, "sputnik.build.json", 524288)
    suggested = if Map === manifest then manifest[?:notebook_packages] else null
    if Array === suggested:
      suggested.take(16).each |name|:
        known = recommendations.any?: $it[:name] == name
        if registry_reference?(name) and not names.include?(name) and not known:
          recommendations.push!({name: name, suggested_by: item[:name]})
  {providers: providers, recommendations: recommendations}

def package_board(packages, provider, type):
  item = packages.find: not $it[?:missing] and $it[:name] == provider
  return null unless item
  entry = descriptor(item[:directory]).find: $it[:id] == type and $it[:kind] == "board"
  return null unless entry
  document = member(item[:directory], entry[:board], 524288)
  return null unless Map === document and document[?:format] == "sputnik-notebook" and document[?:version] == 2
  boards = document[?:boards]
  return null unless Array === boards and boards.count == 1 and Map === boards[0]
  document
