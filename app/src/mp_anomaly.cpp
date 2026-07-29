// mp_anomaly - the market-pulse anomaly detector as a native clink job.
//
// Reads the generated trade tape, keys it by symbol, and runs the stateful
// SpikeDetector (see spike_detector.hpp) over it in-process:
//
//   FileSource<string> -> FlatMap(parse) -> KeyedProcess(SpikeDetector)
//     -> Map(to JSON) -> FileSink<string>
//
// Run from the repository root after `scripts/get-clink.sh`:
//
//   ./app/build/mp_anomaly --in data/trades.ndjson --out out/alerts.ndjson
//
// With the default generator data the detector raises exactly one alert:
// the injected fat-finger print (see data/manifest.json). The stateful
// operator carries a stable uid, so its state is addressable by snapshot
// tooling and restores.

#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include <clink/connectors/file_sink.hpp>
#include <clink/connectors/file_source.hpp>
#include <clink/connectors/text_format.hpp>
#include <clink/operators/flat_map_operator.hpp>
#include <clink/operators/map_operator.hpp>
#include <clink/operators/process_function.hpp>
#include <clink/runtime/dag.hpp>
#include <clink/runtime/local_executor.hpp>
#include <clink/state/in_memory_state_backend.hpp>

#include "spike_detector.hpp"

namespace {

std::string arg_or(int argc, char** argv, const std::string& flag, std::string fallback) {
    for (int i = 1; i + 1 < argc; ++i) {
        if (argv[i] == "--" + flag) {
            return argv[i + 1];
        }
    }
    return fallback;
}

}  // namespace

int main(int argc, char** argv) {
    using namespace clink;

    const std::string in = arg_or(argc, argv, "in", "data/trades.ndjson");
    const std::string out = arg_or(argc, argv, "out", "out/alerts.ndjson");
    const double threshold = std::stod(arg_or(argc, argv, "threshold", "0.15"));
    const auto warmup = std::stoll(arg_or(argc, argv, "warmup", "12"));

    if (!std::filesystem::exists(in)) {
        std::cerr << "input not found: " << in << " (run tools/mpgen.py first)\n";
        return 2;
    }
    std::filesystem::create_directories(std::filesystem::path(out).parent_path());

    Dag dag;

    auto source = std::make_shared<FileSource<std::string>>(in, string_text_format(), 1024);
    auto parse = std::make_shared<FlatMapOperator<std::string, mp::Trade>>(
        [](const std::string& line) {
            std::vector<mp::Trade> one;
            if (auto t = mp::parse_trade(line)) {
                one.push_back(std::move(*t));
            }
            return one;
        });
    auto detector = std::make_shared<mp::SpikeDetector>(threshold, warmup);
    auto keyed = std::make_shared<detail::KeyedProcessFunctionAdapter<std::string, mp::Trade, mp::Alert>>(
        detector, [](const mp::Trade& t) { return t.symbol; }, nullptr, "spike_detector");
    // The stable uid is what makes this operator's state addressable across
    // snapshot, restore and rescale - a stateful operator without one is a
    // correctness bug, not a style choice.
    keyed->set_uid("mp-anomaly-spike-detector");
    auto render = std::make_shared<MapOperator<mp::Alert, std::string>>(
        [](const mp::Alert& a) { return mp::alert_to_json(a); });
    auto sink = std::make_shared<FileSink<std::string>>(out, string_text_format());

    auto h0 = dag.add_source<std::string>(source);
    auto h1 = dag.add_operator<std::string, mp::Trade>(h0, parse);
    auto h2 = dag.add_operator<mp::Trade, mp::Alert>(h1, keyed);
    auto h3 = dag.add_operator<mp::Alert, std::string>(h2, render);
    dag.add_sink<std::string>(h3, sink);

    JobConfig cfg;
    cfg.state_backend = std::make_shared<InMemoryStateBackend>();

    LocalExecutor exec(std::move(dag), std::move(cfg));
    exec.run();

    std::ifstream written(out);
    std::size_t alerts = 0;
    for (std::string line; std::getline(written, line);) {
        ++alerts;
        std::cout << "ALERT " << line << '\n';
    }
    std::cout << alerts << " alert(s) written to " << out << '\n';
    return 0;
}
