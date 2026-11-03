package test.notebook_package_catalog

from net.http import Server, ServerResponse
from sync import Mutex

export PackageCatalogFixture

# Real archives and real HTTP, using the same Sputnik SDK as the consumer.
class PackageCatalogFixture:
  attr origin
  attr downloads
  attr requests

  def init(sdk, @root):
    @downloads = []
    @requests = []
    @archives = {}
    @mutex = Mutex.new()
    stage = root + "/source"
    fs.mkdir_p(stage)
    fs.atomic_write_text(stage + "/main.s", "package test.editor_probe\nexport answer\ndef answer(): 42\n")
    ["0.9.0", "1.0.0", "1.1.0", "2.0.0-rc.1", "3.0.0"].each |version|:
      manifest = {schema: "sputnik.build.v1", name: "test/editor-probe", version: version,
        requires: {sputnik: ">=1.0.0 <2.0.0"}, files: ["main.s"], module_names: {"main.s": "test.editor_probe"},
        capabilities: {"fs.read": ["/package-fixture"]}}
      fs.atomic_write_text(stage + "/sputnik.build.yaml", Json.generate(manifest))
      archive = root + "/" + version + ".sputnikpkg"
      result = system.command(sdk, "pkg", "build", stage, "--out", archive).capture(timeout: 30.0)
      raise ValueError(result.stderr.to_str) unless result.success?
      @archives[version] = fs.read_bytes(archive)
    @server = Server(host: "127.0.0.1", port: 0, workers: 2)
    @origin = "http://127.0.0.1:" + @server.port.to_str
    @runner = task.spawn:
      @server.serve |request|:
        try: dispatch(request)
        rescue Exception |error|:
          io.stderr.write_line("catalog fixture: " + error.message)
          ServerResponse.text(Json.generate({error: error.message}), status: 500)

  def artifact(version, variant):
    body = @archives[version]
    target = {os: (if variant == "foreign" then "windows" else "any"), arch: "any", compute_backend: "none"}
    {package_ref: "test/editor-probe", version: version, variant: variant, target: target,
      native_mode: "none", bundle: "none", compatibility: {sputnik_requirement: ">=1.0.0 <2.0.0"},
      quarantined: false, size: body.count, sha256: "sha256:" + Digest.sha256(body).hex,
      url: @origin + "/api/v1/namespaces/test/packages/editor-probe/versions/" + version + "/artifacts/" + variant + "/download"}

  def archive(version): @archives[version]

  def release(version):
    variants = if version == "0.9.0" then ["foreign"] else ["foreign", "source"]
    {package_ref: "test/editor-probe", version: version, yanked: version == "3.0.0",
      capabilities: [{name: "fs.read", target: "/package-fixture", flags: 0}],
      artifacts: variants.map |variant|: artifact(version, variant)}

  def dispatch(request):
    path = request.path
    @mutex.synchronize: @requests.push!(path)
    task.sleep(0.3) if path.starts_with?("/api/v1/packages/slow/")
    base = "/api/v1/namespaces/test/packages/editor-probe"
    route = path
    ["editor-probe", "slow", "empty"].each |name|:
      alias = "/api/v1/packages/" + name
      if route == alias: route = base
      elif route.starts_with?(alias + "/"): route = base + route.slice(alias.length...route.length)
    version = route.split("/versions/")[-1].split("/")[0]
    if route.ends_with?("/artifacts/source/download") and @archives.has_key?(version):
      @mutex.synchronize: @downloads.push!(version)
      bytes = @archives[version]
      return ServerResponse(body: bytes, headers: {"x-sputnik-sha256": "sha256:" + Digest.sha256(bytes).hex})
    data = null
    status = 200
    if route == base + "/index":
      versions = if path.contains?("/packages/empty/") then [] else @archives.keys.map |v|: release(v)
      data = {package_ref: "test/editor-probe", revision: 1, versions: versions, next_cursor: null}
    elif route.contains?("/artifacts/") and @archives.has_key?(version):
      data = artifact(version, route.split("/artifacts/")[1].split("/")[0])
    elif @archives.has_key?(version): data = release(version)
    elif route == base: data = {package_ref: "test/editor-probe"}
    else:
      status = 404
      data = {error: {code: "NOT_FOUND"}}
    ServerResponse.text(Json.generate(data), status: status, headers: {"content-type": "application/json"})

  def close!():
    @server.close!()
    @runner.wait()
