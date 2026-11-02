package transfer_test
from "../backend/transfer" import Transfer
from notebook.core.host import book_pack
export main
class Checker:
  def call(method, params):
    {bytes: 5}
def main():
  document = "{\"format\":\"sputnik-notebook\",\"version\":1,\"title\":\"Probe\",\"sheets\":[],\"future\":{\"max\":9223372036854775807}}"
  archive = book_pack([["project.json", document.bytes], [".hidden", "hello".bytes]])
  result = task.async: Transfer(null, Checker()).unpack(Base64.encode(archive), null)
  result = result.wait
  raise ValueError("bundle summary differs") unless result[:summary][:files] == 1 and result[:summary][:title] == "Probe"
  raise ValueError("int64 document changed") unless result[:document] == document
  folder = Transfer(null, Checker()).unpack(null, [{path: "Probe.sputnikbook/project.json", data: Base64.encode(document.bytes)}, {path: "Probe.sputnikbook/.hidden", data: Base64.encode("hello".bytes)}])
  raise ValueError("folder and ZIP differ") unless result[:fingerprint] == folder[:fingerprint]
  print "PASS transfer normalization, ZIP/folder identity and untouched int64 document"
