#include "tools/isputnik/session.h"
#include <iostream>
#include <stdexcept>

static void check(bool value, const std::string &message) {
  if (!value) throw std::runtime_error(message);
}

static void failed_import(const std::vector<BundledModuleSource> &sources,
                          const std::string &name, std::size_t line) {
  const auto prepared = prepare_bundled_environment(sources);
  check(!prepared.ok && prepared.diagnostics.size() == 1, "expected one import diagnostic");
  const auto &error = prepared.diagnostics[0];
  check(error.module_id == "consumer" && error.path == "modules/consumer.s", "lost importing module");
  check(error.message.find("Cannot import") != std::string::npos &&
        error.message.find(name) != std::string::npos &&
        error.message.find("modules/consumer.s:" + std::to_string(line) + ":") != std::string::npos,
        "import diagnostic must identify the unavailable name and exact source line: " + error.message);
  check(error.message.find("package") == std::string::npos && error.message.find("VMError") == std::string::npos,
        "import diagnostic must not infer a provider package or expose a VM lookup failure");
  check(error.source_ranges.size() == 1 && error.source_ranges[0].start_line == line &&
        error.source_ranges[0].end_line == line && error.source_ranges[0].has_offsets,
        "import diagnostic lost its source range");
}

int main() {
  try {
    failed_import({{"consumer", "modules/consumer.s",
        "package consumer\n# Unicode before the import: цифры\nfrom unavailable.module import thing\n"}},
        "unavailable.module", 3);
    failed_import({{"consumer", "modules/consumer.s",
        "package consumer\r\n\r\nfrom fs import unavailable_function as renamed\r\n"}},
        "unavailable_function", 3);
    failed_import({{"consumer", "modules/consumer.s",
        "package consumer\n\nfrom notebook.ui import unavailable_function as renamed\n"}},
        "unavailable_function", 3);
    failed_import({{"consumer", "modules/consumer.s",
        "package consumer\nfrom library import missing as renamed\n"},
        {"library", "modules/library.s", "package library\nexport available\ndef available(): 42\n", false}},
        "missing", 2);

    for (const auto &source : {
        "# Header\nfrom fs import unavailable_function\n42\n",
        "# Header\nfrom unavailable.module import thing\n42\n",
        "# Header\nfrom notebook.ui import unavailable_function\n42\n"}) {
      Session session;
      Cell cell; cell.id = 1; cell.source = source;
      session.cells.push_back(std::move(cell));
      evaluate_from(&session, 0, true, false, false);
      check(session.environment_error.find("Cannot import") != std::string::npos,
            "sheet must report its import error: " + session.environment_error);
      check(!session.cells[0].errors.empty() && session.cells[0].errors[0].has_range &&
            session.cells[0].errors[0].range.start_line == 1,
            "sheet import diagnostic must navigate to line 2");
    }

    Session session;
    Cell cell; cell.id = 2;
    cell.source = "from notebook.ui import publish_point, image, publish_images, clear_images, DataTableView, Stopwatch\n"
                  "publish_point(\"loss\", 1, 2)\n"
                  "publish_images(\"digits\", [image([0], width: 1, height: 1, format: :gray)])\n"
                  "clear_images(\"digits\")\n"
                  "notebook.show(DataTableView([[42]], columns: [\"value\"]), id: \"table\")\n"
                  "Stopwatch.measure: 42\n";
    session.cells.push_back(std::move(cell));
    evaluate_from(&session, 0, true, false, false);
    check(session.cells[0].ok && session.cells[0].result == "42",
          "notebook essentials must work without project dependencies: " + session.environment_error + session.cells[0].error);
    std::cout << "PASS notebook import diagnostics and built-in essentials\n";
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
