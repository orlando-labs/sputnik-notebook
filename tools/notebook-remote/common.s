package notebook.remote.common

export APIError, fail, identifier, decode, canonical, digest, terminal?, rpc, project_files, command_at

class APIError < Exception:
  attr status
  attr message
  def init(@status, @message)

def fail(status, message): raise APIError(status, message)

# posix_spawn chdir actions are unavailable on the target glibc 2.28 host.
# The script is constant; directory, executable and arguments remain literal
# positional arguments. exec preserves PID, process-group and timeout handling.
def command_at(directory, program, arguments, env = {}):
  system.command("/bin/sh", "-c", "cd -- \"$1\" && shift && exec \"$@\"", "notebook-command", directory, program, *arguments, env: env)

def identifier(value):
  valid = Str === value and value.length > 0 and value.length <= 128
  valid = valid and value.chars.all? |c|: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".contains?(c)
  fail(400, "invalid identifier") unless valid
  value

def decode(text): Json.parse(text, duplicate_keys: :reject)

def canonical(value):
  case value:
    when (Map | StrictMap):
      result = StrictMap{}
      value.keys.map: $it.to_str .sorted.each |key|:
        result[key] = canonical(value[key])
      result
    when Array:
      value.map: canonical($it)
    else:
      value

def digest(value): Digest.sha256(Json.generate(canonical(value)).bytes).hex

def terminal?(state): ["succeeded", "failed", "cancelled", "force-stopped", "interrupted"].include?(state)

def rpc(root, method, params: {}):
  net.unix.connect(root + "/agent.sock", timeout: 30.0) |socket|:
    socket.write_all!((Json.generate({method: method, params: params}) + "\n").bytes, timeout: 30.0)
    response = socket.read_line!(limit: 100663296, timeout: 30.0)
    raise IOError("execution agent disconnected") unless response
    decode(response.to_str)

# The caller traverses on Sputnik. Symlinks are rejected before following them.
def project_files(directory):
  files = {}
  collect_files(directory, "", files)
  cache = directory + "/vendor/cache"
  if fs.exists?(cache):
    fail(400, "refusing symlink gem cache") if fs.metadata(directory + "/vendor").symlink? or fs.metadata(cache).symlink?
    collect_files(directory, "vendor/cache/", files) if fs.dir?(cache)
  config = directory + "/.bundle/config"
  if fs.exists?(config):
    fail(400, "refusing symlink bundle configuration") if fs.metadata(directory + "/.bundle").symlink? or fs.metadata(config).symlink?
    files[".bundle/config"] = Base64.encode(fs.read_bytes(config, limit: 1048576))
  files

def collect_files(root, prefix, files):
  fs.entries(root + "/" + prefix).filter |path|:
    not path.basename.starts_with?(".") and not (prefix == "" and ["venv", "vendor"].include?(path.basename))
  .each |path|:
    name = path.basename
    relative = prefix + name
    info = fs.metadata(path)
    fail(400, "refusing symlink project member: " + relative) if info.symlink?
    if info.dir?:
      installed = prefix.starts_with?("packages/") and fs.exists?(path.to_str + "/modules.index") and (fs.exists?(path.to_str + "/manifest.json") or fs.exists?(path.to_str + "/sputnik.toml"))
      collect_files(root, relative + "/", files) unless installed
    elif info.file? and relative != "project.json":
      fail(413, "too many project members") if files.count >= 2048
      files[relative] = Base64.encode(fs.read_bytes(path, limit: 16777216))
