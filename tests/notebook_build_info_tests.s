package test.notebook_build_info

export main

def check(value, message):
  raise ValueError(message) unless value

def command(*argv):
  result = system.command(*argv).capture(timeout: 60.0, check: false)
  check(result.success?, result.stdout.to_str + result.stderr.to_str)
  result.stdout.to_str.trim

def commit(directory):
  command("git", "-C", directory, "add", ".")
  command("git", "-C", directory, "-c", "user.name=Notebook Test", "-c", "user.email=notebook@example.invalid",
    "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture")
  command("git", "-C", directory, "rev-parse", "HEAD")

def generate(script, runtime, compiler, plist, output, channel = "development", id = "", env = {}):
  system.command("/bin/bash", script, runtime, compiler, plist, output, channel, id, env: env).capture(timeout: 30.0, check: false)

def generated(script, runtime, compiler, plist, output, channel = "development", id = "", env = {}):
  result = generate(script, runtime, compiler, plist, output, channel, id, env)
  check(result.success?, result.stderr.to_str)
  Json.parse(fs.read_text(output + "/build-info.json"))

def fixtures(root, generator):
  notebook = root + "/Notebook sources"
  runtime = root + "/Language sources"
  output = root + "/Generated metadata"
  script = notebook + "/tools/notebook-macos/generate-build-info.sh"
  plist = notebook + "/Info.plist"
  compiler = root + "/compiler"
  fs.mkdir_p(notebook + "/tools/notebook-macos")
  fs.mkdir_p(runtime + "/runtime")
  fs.atomic_write_text(script, fs.read_text(generator))
  fs.atomic_write_text(plist, "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleShortVersionString</key><string>0.4.0</string><key>CFBundleVersion</key><string>7</string></dict></plist>")
  header = "#define SPUTNIK_VERSION_MAJOR 1\n#define SPUTNIK_VERSION_MINOR 2\n#define SPUTNIK_VERSION_PATCH 3\n"
  fs.atomic_write_text(runtime + "/runtime/version.h", header)
  fs.atomic_write_text(compiler, "#!/bin/sh\nprintf 'sputnik 1.2.3\\n'\n")
  command("chmod", "+x", compiler)
  [notebook, runtime].each |directory|: command("git", "init", "-q", directory)
  notebook_commit = commit(notebook)
  language_commit = commit(runtime)
  initial = generated(script, runtime, compiler, plist, output)
  check(initial[:schema] == "sputnik.notebook.build.v1", "manifest schema")
  check(initial[:notebook][:version] == "0.4.0" and initial[:notebook][:build] == "7", "Notebook release identity")
  check(initial[:notebook][:revision] == notebook_commit and initial[:notebook][:dirty] == false, "Notebook commit and cleanliness")
  check(initial[:sputnik][:version] == "1.2.3" and initial[:sputnik][:revision] == language_commit and initial[:sputnik][:dirty] == false, "exact language/VM identity")
  check(initial[:sputnik][:compilerSHA256] == Digest.sha256(fs.read_bytes(compiler)).hex, "compiler executable fingerprint")

  # Identical metadata must not invalidate an otherwise incremental UI build.
  swift = output + "/NotebookBuildMetadata.swift"
  command("touch", "-t", "200001010000.00", swift)
  stamp = command("stat", "-f", "%m", swift)
  generated(script, runtime, compiler, plist, output)
  check(command("stat", "-f", "%m", swift) == stamp, "unchanged metadata keeps its timestamp")

  # Compile a snapshot, then advance Git: an existing executable retains the
  # original identity even when repackaged after the source checkout changes.
  probe_source = root + "/Probe.swift"
  probe = root + "/probe"
  fs.atomic_write_text(probe_source, "@main enum Probe { static func main() { print(NotebookBuildMetadata.json) } }\n")
  command("xcrun", "swiftc", "-module-cache-path", root + "/swift-cache", swift, probe_source, "-o", probe)
  fs.atomic_write_text(runtime + "/runtime/version.h", header + "// local changes\n")
  modified = generated(script, runtime, compiler, plist, output)
  check(modified[:sputnik][:dirty] == true and modified[:sputnik][:revision] == language_commit, "modified language sources are labelled")
  next_commit = commit(runtime)
  updated = generated(script, runtime, compiler, plist, output, "nightly", "2026-11-01.42")
  check(updated[:sputnik][:revision] == next_commit and updated[:sputnik][:dirty] == false, "commit advance refreshes identity")
  check(updated[:channel] == "nightly" and updated[:buildID] == "2026-11-01.42", "nightly build label")
  frozen = Json.parse(command(probe))
  check(frozen[:sputnik][:revision] == language_commit and frozen[:sputnik][:dirty] == false, "compiled build identity remains frozen")
  check(generated(script, runtime, compiler, plist, output, "daily", "2026-11-01")[:channel] == "daily", "daily build channel")

  fs.atomic_write_text(compiler, "#!/bin/sh\nprintf 'sputnik 1.2.4\\n'\n")
  command("chmod", "+x", compiler)
  rejected = generate(script, runtime, compiler, plist, output)
  check(not rejected.success? and rejected.stderr.to_str.contains?("different Sputnik versions"), "stale compiler/header mismatch is rejected")
  fs.atomic_write_text(compiler, "#!/bin/sh\nprintf 'sputnik 1.2.3\\n'\n# rebuilt\n")
  command("chmod", "+x", compiler)
  rebuilt = generated(script, runtime, compiler, plist, output)
  check(rebuilt[:sputnik][:compilerSHA256] != initial[:sputnik][:compilerSHA256], "rebuilding the compiler changes its fingerprint")

  command("rm", "-rf", "--", runtime + "/.git")
  archive = generated(script, runtime, compiler, plist, output, "release")
  check(archive[:sputnik][:revision] == null and archive[:sputnik][:dirty] == null, "source archive does not invent Git provenance")
  check(not generate(script, runtime, compiler, plist, output, "nightly").success?, "nightly source archive requires a commit")
  archive = generated(script, runtime, compiler, plist, output, "daily", "2026-11-01", {SPUTNIK_SOURCE_REVISION: next_commit})
  check(archive[:sputnik][:revision] == next_commit and archive[:sputnik][:dirty] == null, "CI can supply archive provenance without claiming clean sources")
  print "PASS build identity: exact versions, commits, dirty sources, incremental builds, frozen binaries, nightly/daily labels and archives"

def main():
  parser = ArgParser()
  parser.arg("--generator", required: true)
  parser.arg("--binary", required: true)
  parser.arg("--manifest", required: true)
  args = parser.parse_or_raise
  root = command("mktemp", "-d", "/tmp/spnb-build-info.XXXXXXXX")
  try:
    fixtures(root, args[:generator])
    embedded = command(args[:binary], "--build-info")
    check(embedded == fs.read_text(args[:manifest]).trim, "packaged manifest is the binary's frozen build identity")
    check(Json.parse(embedded)[:sputnik][:version] != "", "real application exports its runtime version without opening a window")
    print "PASS application --build-info and packaged release manifest"
  ensure: command("rm", "-rf", "--", root)
  0
