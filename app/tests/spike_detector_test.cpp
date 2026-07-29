// Tests for the SpikeDetector, written against clink's public testing
// framework (clink::test_support): the keyed harness drives the operator
// directly, per-key state is inspected through the production read path,
// and a snapshot -> restore round trip proves the detector's state
// survives a checkpoint. Plain main(), non-zero exit on failure - no test
// framework dependency.

#include <cstdint>
#include <iostream>
#include <optional>
#include <string>

#include <clink/core/codec.hpp>
#include <clink/test/keyed_harness.hpp>

#include "spike_detector.hpp"

namespace {

int g_failures = 0;

void check(bool ok, const char* what, int line) {
    if (!ok) {
        std::cerr << "FAIL (line " << line << "): " << what << "\n";
        ++g_failures;
    }
}
#define CHECK(cond) check((cond), #cond, __LINE__)

mp::Trade trade(const std::string& sym, double px, std::int64_t id) {
    mp::Trade t;
    t.ts = 1'000 + id;
    t.symbol = sym;
    t.px = px;
    t.qty = 100;
    t.trade_id = id;
    return t;
}

}  // namespace

int main() {
    namespace test = clink::test;
    auto key_fn = [](const mp::Trade& t) { return t.symbol; };
    const auto kc = clink::string_codec();
    const auto vc = clink::trivial_codec<double>();

    auto h = test::make_keyed_process_function_harness(
        mp::SpikeDetector{/*threshold=*/0.15, /*warmup=*/12}, key_fn);
    h.open();

    // Warm-up: gentle drift around 100 must never alert, whatever the size
    // of the move relative to a cold estimator.
    std::int64_t id = 0;
    for (int i = 0; i < 30; ++i) {
        h.process_element(trade("ARDN", 100.0 + 0.2 * static_cast<double>(i % 5), ++id));
    }
    CHECK(h.output_values().empty());

    // State is inspectable through the production read path, per key.
    const auto ewma = h.template state_value<double>("ARDN", "ewma", kc, vc);
    CHECK(ewma.has_value());
    CHECK(*ewma > 99.0 && *ewma < 101.0);
    CHECK(h.template state_value<std::int64_t>("ARDN", "seen") ==
          std::optional<std::int64_t>{30});

    // A second symbol is a separate key with separate state.
    h.process_element(trade("BLKM", 50.0, ++id));
    CHECK(h.template state_value<std::int64_t>("BLKM", "seen") ==
          std::optional<std::int64_t>{1});
    CHECK(h.template state_value<std::int64_t>("ARDN", "seen") ==
          std::optional<std::int64_t>{30});

    // The fat finger: 8x the prevailing price. Exactly one alert, and the
    // estimate must not move towards the bad print.
    h.process_element(trade("ARDN", 800.0, ++id));
    // output_values() returns the flattened values BY VALUE: take a copy
    // before indexing into it (a reference into the temporary would dangle).
    const auto alerts = h.output_values();
    CHECK(alerts.size() == 1);
    if (!alerts.empty()) {
        const auto& a = alerts.front();
        CHECK(a.symbol == "ARDN");
        CHECK(a.px == 800.0);
        CHECK(a.deviation > 6.0);
    }
    const auto ewma_after = h.template state_value<double>("ARDN", "ewma", kc, vc);
    CHECK(ewma_after.has_value() && *ewma_after < 101.0);

    // Snapshot after the incident: the alert branch did not update state,
    // so the snapshot still carries the pre-incident estimate.
    const auto snap = h.snapshot(/*checkpoint_id=*/1);

    // Normal trading resumes: no further alerts.
    h.process_element(trade("ARDN", 100.1, ++id));
    CHECK(h.output_values().size() == 1);
    CHECK(h.template state_value<std::int64_t>("ARDN", "seen") ==
          std::optional<std::int64_t>{31});

    // Restore a fresh harness from the pre-incident snapshot: the estimate
    // and observation count come back, and the same bad print alerts again
    // with the restored baseline.
    auto h2 = test::make_keyed_process_function_harness(
        mp::SpikeDetector{0.15, 12}, key_fn);
    h2.restore_from(snap);
    h2.open();
    CHECK(h2.template state_value<std::int64_t>("ARDN", "seen") ==
          std::optional<std::int64_t>{30});
    const auto restored = h2.template state_value<double>("ARDN", "ewma", kc, vc);
    CHECK(restored.has_value() && *restored > 99.0 && *restored < 101.0);
    h2.process_element(trade("ARDN", 800.0, 999));
    CHECK(h2.output_values().size() == 1);

    if (g_failures == 0) {
        std::cout << "spike_detector_test: all checks passed\n";
        return 0;
    }
    std::cerr << "spike_detector_test: " << g_failures << " check(s) failed\n";
    return 1;
}
