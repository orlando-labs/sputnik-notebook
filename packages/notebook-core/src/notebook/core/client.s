package notebook.core.client

from notebook.core.common import APIError, decode, identifier

export Client

# Optional IPC adapter with the same handle(method, params) contract as Core.
# The agent owns workers and durable state; this connection owns neither.
class Client:
  def init(root as Str, @timeout: 30.0):
    raise ArgumentError("core root must be absolute") unless fs.Path(root).absolute?
    @root = fs.Path(root).normalize.to_str

  def handle(method, params = {}):
    unless Str === method and (Map === params or StrictMap === params):
      raise ArgumentError("core request expects a method and parameter map")
    response = net.unix.connect(@root + "/agent.sock", timeout: @timeout) |socket|:
      socket.write_all!((Json.generate({method: method, params: params}) + "\n").bytes, timeout: @timeout)
      reply = socket.read_line!(limit: 134217728, timeout: @timeout)
      raise IOError("execution agent disconnected") unless reply
      decode(reply.to_str)
    unless Map === response and Int === response[?:status]:
      raise IOError("invalid execution agent response")
    raise APIError(response[:status], response[:error]) unless response[:status] == 200
    response[:data]

  # Local presentation adapter. The record comes from an authorized run.get;
  # never accept a browser-selected filename or follow a symlink artifact.
  def presentation_bytes(record, live: false):
    path = record[if live then :live_presentation else :presentation]
    return null unless path
    expected = @root + "/runs/" + identifier(record[:id]) + (if live then ".live.bin" else ".bin")
    raise IOError("invalid presentation location") unless fs.Path(path).normalize.to_str == expected
    info = fs.metadata(expected)
    raise IOError("invalid presentation artifact") unless info.file? and not info.symlink?
    fs.read_bytes(expected, limit: 134217728)
