#include "notebook/core/worker/presentation.h"
#include "notebook/project.h"
#include "runtime/notebook_image.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sys/wait.h>
#include <unistd.h>
using namespace sputnik::notebook;
using namespace sputnik::notebook::worker;
static void check(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }
int main(int argc, char **argv) {
  if (argc != 2) return 2;
  char temporary[] = "/tmp/sputnik-selection-XXXXXX"; const std::filesystem::path root(mkdtemp(temporary));
  struct Cleanup { std::filesystem::path path; ~Cleanup(){std::filesystem::remove_all(path);} } cleanup{root};
  try {
    auto document = make_project_document("Selection"); document.version = 4;
    document.boards.push_back(parse_project_board(R"({"id":"records","title":"Records","sheet":"main","components":[{"id":"table","kind":"table","title":"Records","cell":"1","selection_id":"record","selection_key":"id"}]})"));
    const auto book = root / "Book.sputnikbook"; std::filesystem::create_directories(book);
    std::ofstream(book / "project.json") << serialize_project_document(document);
    const auto publication = root / "source.bin", payload = root / "selection.json";
    auto source = [&](std::string table) {
      Presentation p; p.status = "done"; CellPresentation cell; cell.id = 1; cell.source_revision = 1; cell.ok = true; cell.dirty = false; cell.result_format.table_json = table; p.cells.push_back(cell);
      std::ofstream output(publication, std::ios::binary); output << encode_presentation(p);
      return sputnik::runtime::notebook_asset_id(table);
    };
    auto accept = [&](const std::string &text, bool expected) {
      std::ofstream(payload) << text;
      const pid_t pid = fork(); check(pid >= 0, "fork failed");
      if (!pid) { auto log = root / "worker.log"; FILE *f = freopen(log.c_str(), "w", stdout); (void)f; execl(argv[1], argv[1], "--media-input", book.c_str(), "records", "table", "json", "selection.json", "annotations", payload.c_str(), publication.c_str(), nullptr); _exit(127); }
      int status = 0; waitpid(pid, &status, 0); check((WIFEXITED(status) && WEXITSTATUS(status) == 0) == expected, "selection worker result mismatch");
    };
    const auto table = R"({"columns":[{"id":"0","title":"id","type":"integer"},{"id":"1","title":"name","type":"text"}],"rows":[{"id":"0","values":[9223372036854775807,"Alpha"]},{"id":"1","values":[9223372036854775806,"Beta"]}],"total_rows":2,"truncated":false})";
    auto identity = source(table);
    auto labels = [&](std::string row, std::string key="9223372036854775807") { return "{\"version\":1,\"source\":\"" + identity + "\",\"key\":" + key + ",\"row\":" + row + "}"; };
    const auto row = R"({"id":9223372036854775807,"name":"Alpha"})";
    accept(labels(row), true); accept(labels(R"({"id":9223372036854775807,"name":"Forged"})"), false); accept(labels(row,"9223372036854775806"), false); accept(labels(row,"null"), false);
    identity = std::string(64,'a'); accept(labels(row), false);
    identity = source(R"({"columns":[{"id":"0","title":"id","type":"integer"}],"rows":[{"id":"0","values":[1]},{"id":"1","values":[1]}],"total_rows":2,"truncated":false})"); accept(labels("{\"id\":1}","1"), false);
    identity = source(R"({"columns":[{"id":"0","title":"id","type":"null"}],"rows":[{"id":"0","values":[null]}],"total_rows":1,"truncated":false})"); accept(labels("{\"id\":null}","null"), false);
    identity = source(R"({"columns":[{"id":"0","title":"id","type":"integer"},{"id":"1","title":"id","type":"integer"}],"rows":[{"id":"0","values":[1,2]}],"total_rows":1,"truncated":false})"); accept(labels("{\"id\":1}","1"), false);
    accept("null", true);
    std::cout << "PASS shared selection worker: exact Int64 source row, forged row/key/hash rejection, duplicate/null keys, ambiguous columns, Clear and immutable publication codec\n";
  } catch (const std::exception &error) { std::cerr << error.what() << '\n'; return 1; }
}
