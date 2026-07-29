#pragma once

// The market-pulse anomaly detector: a keyed, stateful clink operator.
//
// Per symbol, an exponentially weighted moving average of the trade price
// lives in clink keyed state. A print deviating from that average by more
// than `threshold` (relative) after `warmup` observations raises an Alert;
// alerted prints do not update the average, so one bad tick cannot poison
// the estimate that caught it. State rides clink's KeyedState slots, which
// is what makes the operator checkpointable, restorable and inspectable by
// the test harness through the production read path.

#include <cmath>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>

#include <clink/core/codec.hpp>
#include <clink/operators/process_function.hpp>
#include <clink/state/keyed_state.hpp>

namespace mp {

struct Trade {
    std::int64_t ts{};
    std::string symbol;
    double px{};
    std::int64_t qty{};
    std::int64_t trade_id{};
};

struct Alert {
    std::int64_t ts{};
    std::string symbol;
    double px{};
    double ewma{};
    double deviation{};  // |px - ewma| / ewma
    std::int64_t trade_id{};
};

// Minimal parser for the generator's fixed trade schema. Field order does
// not matter; unknown fields are ignored. Deliberately dependency-free so
// the app builds against clink::core alone - a production job would use a
// JSON library or clink's SQL layer instead.
inline std::optional<Trade> parse_trade(const std::string& line) {
    auto find_raw = [&](const char* key) -> std::optional<std::string> {
        const std::string needle = std::string{"\""} + key + "\":";
        const auto at = line.find(needle);
        if (at == std::string::npos) {
            return std::nullopt;
        }
        auto begin = at + needle.size();
        auto end = begin;
        if (begin < line.size() && line[begin] == '"') {
            ++begin;
            end = line.find('"', begin);
            if (end == std::string::npos) {
                return std::nullopt;
            }
        } else {
            while (end < line.size() && line[end] != ',' && line[end] != '}') {
                ++end;
            }
        }
        return line.substr(begin, end - begin);
    };
    try {
        Trade t;
        const auto ts = find_raw("ts");
        const auto symbol = find_raw("symbol");
        const auto px = find_raw("px");
        const auto qty = find_raw("qty");
        const auto id = find_raw("trade_id");
        if (!ts || !symbol || !px || !qty || !id) {
            return std::nullopt;
        }
        t.ts = std::stoll(*ts);
        t.symbol = *symbol;
        t.px = std::stod(*px);
        t.qty = std::stoll(*qty);
        t.trade_id = std::stoll(*id);
        return t;
    } catch (const std::exception&) {
        return std::nullopt;
    }
}

inline std::string alert_to_json(const Alert& a) {
    return std::string{"{\"ts\":"} + std::to_string(a.ts) + ",\"symbol\":\"" + a.symbol +
           "\",\"px\":" + std::to_string(a.px) + ",\"ewma\":" + std::to_string(a.ewma) +
           ",\"deviation\":" + std::to_string(a.deviation) +
           ",\"trade_id\":" + std::to_string(a.trade_id) + "}";
}

class SpikeDetector final : public clink::KeyedProcessFunction<std::string, Trade, Alert> {
public:
    explicit SpikeDetector(double threshold = 0.15, std::int64_t warmup = 12, double alpha = 0.05)
        : threshold_(threshold), warmup_(warmup), alpha_(alpha) {}

    void open(clink::RuntimeContext& ctx) override {
        ewma_.emplace(ctx.keyed_state<std::string, double>(
            "ewma", clink::string_codec(), clink::trivial_codec<double>()));
        seen_.emplace(ctx.keyed_state<std::string, std::int64_t>(
            "seen", clink::string_codec(), clink::int64_codec()));
    }

    void process_element(const Trade& t,
                         clink::ProcessFunctionContext<Alert>& /*ctx*/,
                         clink::Collector<Alert>& out) override {
        const auto& key = current_key();
        const auto seen = seen_->get(key).value_or(0);
        const auto ewma = ewma_->get(key);

        if (ewma.has_value() && seen >= warmup_) {
            const double dev = std::abs(t.px - *ewma) / *ewma;
            if (dev > threshold_) {
                out.collect(Alert{t.ts, t.symbol, t.px, *ewma, dev, t.trade_id});
                // An alerted print is treated as erroneous: it must not drag
                // the average towards itself, or a fat finger would raise
                // the very baseline that caught it.
                return;
            }
        }
        const double next = ewma.has_value() ? (1.0 - alpha_) * *ewma + alpha_ * t.px : t.px;
        ewma_->put(key, next);
        seen_->put(key, seen + 1);
    }

private:
    double threshold_;
    std::int64_t warmup_;
    double alpha_;
    std::optional<clink::KeyedState<std::string, double>> ewma_;
    std::optional<clink::KeyedState<std::string, std::int64_t>> seen_;
};

}  // namespace mp
