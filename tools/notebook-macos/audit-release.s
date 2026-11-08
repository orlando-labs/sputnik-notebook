package notebook.release_audit

export main

def check(value, message):
  raise ValueError(message) unless value

def execute(*argv):
  system.command(*argv).capture(timeout: 60.0, check: false)

def command(*argv):
  result = execute(*argv)
  check(result.success?, result.stdout.to_str + result.stderr.to_str)
  result.stdout.to_str.trim

def write_json(path, value):
  fs.atomic_write_text(path, Json.pretty_generate(value) + "\n")

def version_key(version):
  parts = (version + ".0.0").split(".")
  parts[0].to_int * 1000000 + parts[1].to_int * 1000 + parts[2].to_int

def main():
  parser = ArgParser()
  parser.arg("--release", required: true)
  root = parser.parse_or_raise[:release]
  artifacts = root + "/artifacts"
  app = artifacts + "/Sputnik Notebook.app"
  contents = app + "/Contents"
  resources = contents + "/Resources"
  executable = contents + "/MacOS/SputnikNotebook"
  identity = Json.parse(command(executable, "--build-info"))
  check(identity == Json.parse(fs.read_text(resources + "/build-info.json")), "embedded and packaged build identities differ")
  check(identity[:channel] == "release", "application must carry release metadata")
  check(Json.parse(fs.read_text(resources + "/distribution-info.json"))[:notarized] == false, "ad-hoc distribution must not claim notarization")
  minimum = command("plutil", "-extract", "LSMinimumSystemVersion", "raw", "-o", "-", contents + "/Info.plist")
  check(command("find", app, "-type", "l", "-print").empty?, "release bundle contains symbolic links")
  paths = ["SputnikNotebook", "sputnik-notebook-worker", "sputnik-notebook-remote", "sputnik"].map: contents + "/MacOS/" + _1
  libraries = command("find", contents + "/Frameworks", "-type", "f", "-name", "*.dylib").split("\n").sorted
  paths += libraries
  components = paths.map |path|:
    name = path.split("/")[-1]
    architecture = command("lipo", "-archs", path)
    check(architecture == "arm64", "unexpected architecture: #{name}: #{architecture}")
    loads = command("otool", "-l", path).split("\n").map: _1.trim
    rpaths = loads.select: _1.starts_with?("path ")
    rpaths.each |entry|:
      loader_path = entry.split(" (offset ")[0]
      check(loader_path in ["path /usr/lib/swift", "path @executable_path/../Frameworks", "path @loader_path/../lib"],
        "unexpected loader path in #{name}: #{loader_path}")
    dependencies = command("otool", "-L", path).split("\n").drop(1).map |line|:
      line.trim.split(" (compatibility version")[0]
    dependencies.each |dependency|:
      if dependency.starts_with?("/System/Library/") or dependency.starts_with?("/usr/lib/"):
        null
      elif dependency.starts_with?("@rpath/"):
        check(fs.exists?(contents + "/Frameworks/" + dependency.split("/")[-1]), "unbundled dependency: #{dependency}")
      else:
        raise ValueError("unexpected dependency in #{name}: #{dependency}")
    build = command("xcrun", "vtool", "-show-build", path)
    targets = build.split("\n").map: _1.trim
    targets = targets.select: _1.starts_with?("minos ")
    targets.each |target|:
      parts = target.split(" ").select: not _1.empty?
      check(version_key(parts[1]) <= version_key(minimum), "bundle understates minimum macOS for #{name}")
    command("codesign", "--verify", "--strict", path)
    {path: path.replace(app + "/", ""), bytes: fs.metadata(path).size,
     sha256: Digest.sha256(fs.read_bytes(path)).hex, architecture:, dependencies:}
  command("codesign", "--verify", "--deep", "--strict", app)
  signing = execute("codesign", "--display", "--verbose=4", app)
  signing_text = signing.stdout.to_str + signing.stderr.to_str
  check(signing.success? and signing_text.contains?("Signature=adhoc") and signing_text.contains?("TeamIdentifier=not set"), "expected an ad-hoc signature without a Developer ID")
  fs.atomic_write_text(root + "/logs/codesign.txt", signing_text)
  assessment = execute("spctl", "--assess", "--type", "execute", "--verbose=4", app)
  assessment_text = assessment.stdout.to_str + assessment.stderr.to_str
  gatekeeper = if assessment.success?:
    "accepted"
  elif assessment_text.contains?("rejected"):
    "rejected"
  else:
    "unavailable"
  fs.atomic_write_text(root + "/logs/gatekeeper.txt", assessment_text)
  ["ca-certificates.crt", "notebook-essentials/src/notebook_ui.s", "notebook-essentials/src/audio.s",
   "sputnik-sdk/runtime/sputnik_ext.h", "sputnik-sdk/runtime/version.h", "THIRD_PARTY_NOTICES.md"].each |file|:
    check(fs.exists?(resources + "/" + file), "missing bundled resource: #{file}")
  licenses = libraries.map |path|:
    name = path.split("/")[-1]
    notices = command("find", resources, "-maxdepth", "1", "-type", "f", "-name", name + "-*").split("\n").select: not _1.empty?
    check(not notices.empty?, "missing license notice for #{name}")
    names = notices.map: _1.split("/")[-1]
    {library: name, notices: names}
  sources = ["sputnik-notebook", "sputnik-lang", "orbit", "orm", "sqlite3", "plot"].map |repository|:
    {repository:, revision: fs.read_text(root + "/provenance/" + repository + ".commit").trim,
     dirty: not fs.read_text(root + "/provenance/" + repository + ".status").trim.empty?,
     filesSHA256: Digest.sha256(fs.read_bytes(root + "/provenance/" + repository + ".sources")).hex}
  manifest = {schema: "sputnik.notebook.release.v1", identity:, architecture: "arm64", minimumMacOS: minimum,
    signature: {kind: "ad-hoc", valid: true, developerID: false, notarized: false, gatekeeperAssessment: gatekeeper},
    components:, licenses:, sources:,
    tools: {swift: command("xcrun", "swiftc", "--version"), clang: command("clang", "--version"), macOS: command("sw_vers", "-productVersion")}}
  write_json(artifacts + "/release.json", manifest)
  print "PASS release metadata, #{components.count} Mach-O files, #{libraries.count} bundled libraries, licenses and ad-hoc signatures"
  print "Gatekeeper assessment: #{gatekeeper}; Developer ID absent; not notarized"
  0
