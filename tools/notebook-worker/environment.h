#pragma once
#include "tools/notebook-worker/protocol.h"
#include "frontend/lexer/lexer.h"
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <unistd.h>

namespace sputnik::notebook::worker {
// Discovery reads launch facts; it never executes Python, Ruby or a Gemfile.
struct Environment {
  std::string directory, python, gemfile, fingerprint;
  static Environment discover(const std::string &root) {
    namespace fs = std::filesystem;
    Environment result;
    if (root.empty()) return result;
    if (root.front() != '/' || root.find('\0') != std::string::npos || !fs::is_directory(root))
      throw ProtocolError("worker environment directory must be an existing absolute directory");
    result.directory = fs::weakly_canonical(root).string();
    std::string material = "sputnik.worker.environment.v1\n";
    auto record = [&](const fs::path &path, const std::string &label) {
      material += label + "\n";
      if (!fs::exists(path)) { material += "absent\n"; return; }
      if (!fs::is_regular_file(path)) throw ProtocolError("invalid environment file: " + path.string());
      std::ifstream input(path, std::ios::binary);
      if (!input) throw ProtocolError("cannot read environment file: " + path.string());
      std::string contents;
      char buffer[4096];
      while (input.read(buffer, sizeof buffer) || input.gcount()) {
        contents.append(buffer, input.gcount());
        if (contents.size() > 1048576) throw ProtocolError("environment configuration exceeds 1 MiB");
      }
      material += std::to_string(contents.size()) + ":" + contents + "\n";
    };
    for (const char *name : {".venv", "venv"}) {
      const auto venv = fs::path(result.directory) / name;
      if (!fs::exists(venv / "pyvenv.cfg")) continue;
      const auto python = venv / "bin/python";
      if (!fs::is_regular_file(python) || ::access(python.c_str(), X_OK))
        throw ProtocolError("virtual environment has no executable bin/python: " + venv.string());
      result.python = python.string(); // Preserve the venv symlink.
      record(venv / "pyvenv.cfg", name);
      material += result.python + "\n" + fs::canonical(python).string() + "\n";
      break;
    }
    const auto gemfile = fs::path(result.directory) / "Gemfile";
    if (fs::exists(gemfile)) {
      result.gemfile = gemfile.string();
      record(gemfile, "Gemfile");
      record(gemfile.string() + ".lock", "Gemfile.lock");
      record(fs::path(result.directory) / ".bundle/config", ".bundle/config");
    }
    result.fingerprint = lexer::sha256_hex(material);
    return result;
  }
  void apply() const {
    auto set = [](const char *name, const std::string &value) {
      if (::setenv(name, value.c_str(), 1)) throw ProtocolError("cannot configure worker environment");
    };
    set("SPUTNIK_PYTHON_EXECUTABLE", python);
    set("SPUTNIK_RBCALL_BUNDLE_GEMFILE", gemfile);
    if (!python.empty()) {
      set("VIRTUAL_ENV", std::filesystem::path(python).parent_path().parent_path().string());
      ::unsetenv("PYTHONHOME");
    }
    if (!gemfile.empty()) {
      set("BUNDLE_GEMFILE", gemfile);
      set("BUNDLE_APP_CONFIG", std::filesystem::path(gemfile).parent_path().string() + "/.bundle");
      set("BUNDLE_FROZEN", "true");
    }
  }
};
} // namespace sputnik::notebook::worker
