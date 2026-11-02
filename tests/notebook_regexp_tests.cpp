#include "tools/isputnik/session.h"
#include <cstdlib>
#include <iostream>

int main() {
  Session session;
  Cell cell;
  cell.id = 1;
  cell.source = R"SPUTNIK(
needle = "я+"
pattern = r"\A#{needle}\z"i
raise ValueError("symmetric regexp") unless pattern ~= "Я+" and "Я+" ~= pattern
raise ValueError("suffix flags") unless r"^[a-z]+$"mi.match?("0\nABC\n1")
hit = r"(?<letter>.)(x)?".match("я")
raise ValueError("Unicode captures") unless hit[:letter] == "я" and hit.end == 1 and hit.byte_end == 2
if pattern.match("Я+"):
  raise ValueError("condition result") unless $_[0] == "Я+"
else:
  raise ValueError("regexp condition")
10
if 20 and ($_ + 2):
  raise ValueError("logical condition") unless $_ == 12
raise ValueError("zero-width progress") unless r"(?:|a)".scan("a").length == 3
42
)SPUTNIK";
  session.cells.push_back(cell);
  evaluate_from(&session, 0, true, false, false);
  if (!session.cells[0].ok || session.cells[0].result != "42") {
    std::cerr << "notebook regexp regression: " << session.cells[0].error
              << " / " << session.cells[0].result << '\n';
    return 1;
  }
  for (const auto *op : {"=~", "!~"}) {
    Session removed;
    Cell invalid;
    invalid.id = 1;
    invalid.source = std::string("\"x\" ") + op + " r\"x\"\n";
    removed.cells.push_back(invalid);
    evaluate_from(&removed, 0, true, false, false);
    if (removed.cells[0].ok) {
      std::cerr << "notebook accepted removed operator " << op << '\n';
      return 1;
    }
  }
  std::cout << "notebook_regexp_tests: ok\n";
}
