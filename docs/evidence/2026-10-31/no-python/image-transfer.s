package maintenance.image_transfer

from net.http import Server, ServerResponse

export main

def main():
  parser = ArgParser()
  parser.arg("--archive", required: true)
  args = parser.parse_or_raise
  server = Server(host: "0.0.0.0", port: 8000, workers: 2)
  server.serve |request|:
    if not ["192.168.1.15", "192.168.1.70"].include?(request.remote_endpoint.host):
      ServerResponse.text("forbidden", status: 403)
    elif request.path != "/core-image.tar.gz" or request.method != "GET":
      ServerResponse.text("not found", status: 404)
    else:
      ServerResponse(body: fs.read_bytes(args[:archive]), headers: {"content-type": "application/gzip"})
  0
