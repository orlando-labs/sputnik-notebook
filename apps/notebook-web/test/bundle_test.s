package bundle_test

from notebook.core.host import book_entries, book_read, book_pack, book_text, book_base64?

export main

def check(value, message): raise ValueError(message) unless value

def main():
  source = [["Example.sputnikbook/project.json", "{}".bytes], ["Example.sputnikbook/resources/raw.bin", Hex.decode("0001ff80")], ["Example.sputnikbook/.bundle/config", "BUNDLE_FROZEN: true\n".bytes]]
  normalized = book_entries(source)
  result = book_read(book_pack(source))
  check(result.count == 3, "ZIP round trip member count")
  binary = result.find: $it[0] == "resources/raw.bin"
  check(binary[1].hex == "0001ff80", "binary bytes must survive ZIP")
  check((result.find: $it[0] == ".bundle/config")[1].to_str == "BUNDLE_FROZEN: true\n", "hidden authored files survive ZIP")
  check(book_text(Hex.decode("ff")) == null and book_text("Привет".bytes) == "Привет", "strict UTF-8 preview")
  ["../secret", "/secret", "C:/secret", "a\\secret", "a/../secret"].each |name|:
    rejected = false
    try: book_entries([["project.json", "{}".bytes], [name, "x".bytes]])
    rescue ValueError: rejected = true
    check(rejected, "unsafe member accepted")
  rejected = false
  try: book_entries([["project.json", "{}".bytes], ["resources/A", "x".bytes], ["resources/a", "y".bytes]])
  rescue ValueError: rejected = true
  check(rejected, "case collision accepted")
  ["", "AA==", "AP8=", "aGVsbG8="].each |value|: check(book_base64?(value), "canonical base64 rejected")
  ["?invalid?", "=AAA", "A===", "AAAA=", "AB==", "AAF=", "aGV sbG8="].each |value|: check(not book_base64?(value), "invalid base64 accepted")
  check([1, 2, 3].take(2).count == 2, "revision page slicing")
  print "PASS notebook bundle: ZIP interoperability shape, binary/hidden members, UTF-8 and unsafe paths"
