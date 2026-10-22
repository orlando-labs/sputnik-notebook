#include "notebook/project.h"
#include "tools/notebook-worker/process.h"
#include "tools/notebook-worker/presentation.h"
#include <algorithm>
#include <iomanip>
#include <iostream>
#include <stdexcept>

using namespace sputnik::notebook;
using namespace sputnik::notebook::worker;
using namespace std::chrono_literals;

static Presentation receive(Process &process, RequestId id) {
  PresentationAssembler terminal(id.generation, id.request);
  std::optional<PresentationAssembler> live;
  while (true) {
    auto message = process.receive(30s);
    if (!message) throw std::runtime_error("MNIST benchmark timeout");
    if (message->kind == Kind::Error) throw std::runtime_error(message->fields.at(0));
    if (message->kind == Kind::Started || message->kind == Kind::Draining) continue;
    if (message->kind == Kind::LiveBegin || message->kind == Kind::LiveChunk || message->kind == Kind::LiveEnd) {
      if (!live) live.emplace(id.generation, id.request, true);
      if (live->accept(*message)) live.reset();
    } else if (auto value = terminal.accept(*message)) return *value;
  }
}
int main(int argc, char **argv) {
  try {
    if (argc != 3) throw std::runtime_error("usage: notebook-mnist-benchmark ABSOLUTE_WORKER PREPARED_PROJECT");
    auto project = load_project(argv[2]);
    const auto &cells = project.document.sheets[0].cells;
    const auto settings = std::find_if(cells.begin(), cells.end(), [](const auto &c) { return c.kind == "code"; });
    const auto training = std::find_if(cells.begin(), cells.end(), [](const auto &c) { return c.source.find("metrics = train_mnist") != std::string::npos; });
    if (settings == cells.end() || training == cells.end()) throw std::runtime_error("not a MNIST fixture");
    Process process; process.start(argv[1]);
    if (!process.receive(5s)) throw std::runtime_error("worker handshake failed");
    receive(process, process.send(Kind::Load, {project.directory.string(), "", "1"}));
    auto warmup = receive(process, process.send(Kind::Run, {std::to_string(settings->id), "1"}));
    for (const auto &c : warmup.cells) if (!c.error.empty()) throw std::runtime_error(c.error);
    // All modes use the same model, optimizer, seed, scalar loss extraction,
    // dataset and evaluation. Only notebook presentation differs.
    const std::vector<std::string> modes = {"none", "board", "plot", "plot", "board", "none"};
    std::map<std::string, std::vector<double>> results;
    for (const auto &mode : modes) {
      const auto source = "metrics = train_mnist(dataset, device: \"mps\", epochs: 2, batch_size: 128, "
          "train_limit: 16384, test_limit: 1024, plot_throttle_ms: 500, visualization: :" + mode + ")\n"
          "seconds = metrics[:seconds]\naccuracy = metrics[:accuracy]\ntest_loss = metrics[:test_loss]\nmetrics\n";
      receive(process, process.send(Kind::Source, {std::to_string(training->id), source, "0"}));
      auto value = receive(process, process.send(Kind::Run, {std::to_string(settings->id), "1"}));
      double seconds = 0;
      for (const auto &cell : value.cells) {
        if (!cell.error.empty()) throw std::runtime_error(cell.error);
        if (cell.id == training->id) for (const auto &local : cell.locals)
          if (local.name == "seconds") seconds = std::stod(local.value);
      }
      if (seconds <= 0) throw std::runtime_error("missing benchmark duration");
      results[mode].push_back(seconds);
      std::cout << mode << ": " << std::setprecision(6) << seconds << " s, " << 256 / seconds << " optimizer steps/s" << std::endl;
    }
    auto mean = [&](const char *mode) { const auto &v = results.at(mode); return (v[0] + v[1]) / 2; };
    std::cout << "Mean board overhead vs none: " << (mean("board") / mean("none") - 1) * 100
              << "%\nMean synchronous plot overhead vs none: " << (mean("plot") / mean("none") - 1) * 100 << "%\n";
    process.send(Kind::Shutdown); process.receive(5s);
  } catch (const std::exception &e) { std::cerr << e.what() << '\n'; return 1; }
}
