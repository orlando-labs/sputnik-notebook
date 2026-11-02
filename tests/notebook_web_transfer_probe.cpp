#include "notebook/core/notebook.h"
#include "notebook/project.h"
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>

// Test-only adapter for the exact owner-queue C API used by the Swift app.
// Opening, editing and saving are inert; execution is explicitly disabled.
int main(int argc, char **argv) {
  if (argc < 2 || argc > 4) return 2;
  SputnikNotebook *book = nullptr;
  try {
    char *error = nullptr;
    book = sputnik_notebook_open(argv[1], 0, nullptr, &error);
    if (!book) throw std::runtime_error(error ? error : "open failed");
    const auto check = [&](int result) {
      if (!result) throw std::runtime_error(error ? error : "native command failed");
    };
    check(sputnik_notebook_external(book, 1, &error));
    if (argc >= 3) check(sputnik_notebook_command(book, "source", "sheet:main", "9007199254740993", argv[2], &error));
    check(sputnik_notebook_command(book, "save_all", nullptr, nullptr, nullptr, &error));
    const char *encoded = sputnik_notebook_export(book, &error);
    if (!encoded) throw std::runtime_error(error ? error : "export failed");
    if (argc == 4) { std::ofstream output(argv[3]); output << encoded; if (!output) throw std::runtime_error("cannot write native export"); }
    else std::cout << encoded << '\n';
    sputnik_notebook_string_free(const_cast<char *>(encoded));
    sputnik_notebook_destroy(book);
    return 0;
  } catch (const std::exception &error) {
    if (book) sputnik_notebook_destroy(book);
    std::cerr << "native transfer probe: " << error.what() << '\n';
    return 1;
  }
}
