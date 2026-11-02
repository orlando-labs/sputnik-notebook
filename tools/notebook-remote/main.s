package notebook.remote.main

from notebook.remote.server import agent, gateway
from notebook.remote.client import client
from notebook.remote.local_dependencies import local_dependencies
from notebook.remote.service import serve

export main

def main():
  parser = ArgParser(name: "sputnik-notebook-remote")
  parser.arg("--mode", choices: ["serve", "agent", "gateway", "cli", "dependencies"], required: true)
  parser.arg("--root")
  parser.arg("--worker")
  parser.arg("--python", default: "python3")
  parser.arg("--ruby", default: "ruby")
  parser.arg("--sputnik", default: "sputnik")
  parser.arg("--orphan-gc-interval", type: Int, default: 0)
  parser.arg("--orphan-min-age", type: Int, default: 604800)
  parser.arg("--storage-policy")
  parser.arg("--policy-file")
  parser.flag("--allow-book-policy-overrides")
  parser.arg("--before", type: Int)
  parser.arg("--limit", type: Int)
  parser.arg("--board")
  parser.arg("--component")
  parser.arg("--port", type: Int, default: 18765)
  parser.arg("--host", default: "127.0.0.1")
  parser.arg("--url", default: "http://127.0.0.1:18765")
  parser.arg("--token-file")
  parser.arg("--command")
  parser.arg("--project")
  parser.arg("--directory")
  parser.arg("--base")
  parser.arg("--revision")
  parser.arg("--sheet", default: "main")
  parser.arg("--cell", default: "1")
  parser.arg("--run-id")
  parser.arg("--epoch")
  parser.arg("--command-id")
  parser.arg("--snapshot-file")
  parser.arg("--request-file")
  parser.arg("--output")
  parser.flag("--json-errors")
  parser.flag("--all")
  parser.flag("--force")
  args = parser.parse_or_raise()
  if args[:mode] == "dependencies": local_dependencies(args)
  elif args[:mode] == "cli":
    client(args)
  else:
    raise ArgumentError("--root must be absolute") unless args[:root] and fs.Path(args[:root]).absolute?
    root = fs.Path(args[:root]).normalize.to_str
    if args[:mode] == "serve": serve(root, args)
    elif args[:mode] == "agent": agent(root, args[:worker], args[:python], args[:ruby], args[:orphan_gc_interval], args[:orphan_min_age], args[:sputnik], (if args[?:policy_file] or args[?:storage_policy] then Json.parse(fs.read_text(args[?:policy_file] or args[:storage_policy])) else {}), args[:allow_book_policy_overrides])
    else: gateway(root, args[:port], host: args[:host])
  null
