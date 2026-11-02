package source_test
from "../backend/sources" import apply_changes, member_path, Sources
export main
def check(value, message): raise ValueError(message) unless value
class Catalog:
  def require_project(current, id): {core_project_id: "probe"}
class Notebooks:
  def call(method, params): {document: "{}", files: {"binary": "AAH/gA=="}}
def main():
  check(member_path("modules/hello.s") == "modules/hello.s", "valid member")
  result = apply_changes({".hidden": Base64.encode("hidden".bytes)}, {"modules/hello.s": {encoding: "utf8", data: "package hello\n"}})
  check(result.count == 2, "merged files")
  result = apply_changes(result, {".hidden": null, "resources/bin": {encoding: "base64", data: "AP8="}})
  check(result.count == 2 and Base64.decode(result["resources/bin"]).hex == "00ff", "binary and delete")
  ["../x", "/x", "a\\b", "a\nb", "C:/x", "PROJECT.json"].each |path|:
    rejected = false
    try: member_path(path)
    rescue Exception: rejected = true
    check(rejected, "unsafe path accepted")
  result = task.async: Sources(Catalog(), Notebooks()).read({}, "project", "a" * 64, "binary")
  result = result.wait
  check(result[:preview] == null, "binary preview")
  print "PASS source member validation and atomic file merge"
