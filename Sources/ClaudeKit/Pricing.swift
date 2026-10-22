import Foundation

/// Published list prices in USD per million tokens.
/// Source: https://platform.claude.com/docs/en/about-claude/pricing
/// (page checked 2026-10-22; rate card effective 2026-10-07).
/// Cache writes without a 5-minute / 1-hour split are priced at the 5-minute rate.
struct ModelRate: Sendable {
    var input: Decimal
    var cache5m: Decimal
    var cache1h: Decimal
    var cacheRead: Decimal
    var output: Decimal
}

enum ListPrices {
    static let table: [(prefix: String, rate: ModelRate, long: (Int, ModelRate)?)] = [
        ("claude-fable-5-1", rate("10", "12.50", "20", "0.25", "50"), nil),
        ("claude-mythos-5-1", rate("10", "12.50", "20", "0.25", "50"), nil),
        ("claude-fable-5", rate("10", "12.50", "20", "1", "50"), nil),
        ("claude-mythos-5", rate("10", "12.50", "20", "1", "50"), nil),
        ("claude-opus-5-5", rate("4", "5", "8", "0.20", "20"), nil),
        ("claude-opus-5", rate("5", "6.25", "10", "0.50", "25"), nil),
        ("claude-opus-4-8", rate("5", "6.25", "10", "0.50", "25"), nil),
        ("claude-opus-4-7", rate("5", "6.25", "10", "0.50", "25"), nil),
        ("claude-opus-4-6", rate("5", "6.25", "10", "0.50", "25"), nil),
        ("claude-opus-4-5", rate("5", "6.25", "10", "0.50", "25"), nil),
        ("claude-opus-4-1", rate("15", "18.75", "30", "1.50", "75"), nil),
        ("claude-opus-4", rate("15", "18.75", "30", "1.50", "75"), nil),
        ("claude-sonnet-5-5", rate("2", "2.50", "4", "0.10", "10"), nil),
        ("claude-sonnet-5", rate("2", "2.50", "4", "0.20", "10"), nil),
        ("claude-sonnet-4-6", rate("3", "3.75", "6", "0.30", "15"), nil),
        ("claude-sonnet-4-5", rate("3", "3.75", "6", "0.30", "15"), nil),
        ("claude-sonnet-4", rate("3", "3.75", "6", "0.30", "15"), nil),
        ("claude-haiku-5-5", rate("0.10", "0.125", "0.20", "0.01", "0.50"), (100_000, rate("0.50", "0.625", "1", "0.05", "2.50"))),
        ("claude-haiku-4-5", rate("1", "1.25", "2", "0.10", "5"), nil),
        ("claude-haiku-3-5", rate("0.80", "1", "1.60", "0.08", "4"), nil),
    ]

    static func costUSD(usage: TokenUsage, model: String) -> Decimal? {
        guard let match = rate(for: model) else { return nil }
        let prompt = usage.input + usage.cacheCreation + usage.cacheRead
        var selected = match.rate
        if let long = match.long, prompt > long.0 {
            selected = long.1
        }
        var total = Decimal(usage.input) * selected.input
        total += Decimal(usage.output) * selected.output
        total += Decimal(usage.cacheRead) * selected.cacheRead
        if usage.cache5m != nil || usage.cache1h != nil {
            let five = usage.cache5m ?? 0
            let hour = usage.cache1h ?? 0
            total += Decimal(five) * selected.cache5m
            total += Decimal(hour) * selected.cache1h
            let remainder = max(0, usage.cacheCreation - five - hour)
            total += Decimal(remainder) * selected.cache5m
        } else {
            total += Decimal(usage.cacheCreation) * selected.cache5m
        }
        return total / Decimal(1_000_000)
    }

    private static func rate(for model: String) -> (rate: ModelRate, long: (Int, ModelRate)?)? {
        let name = model.lowercased()
        let ordered = table.sorted { $0.prefix.count > $1.prefix.count }
        for entry in ordered where name.hasPrefix(entry.prefix) {
            return (entry.rate, entry.long)
        }
        return nil
    }

    private static func rate(_ input: String, _ cache5m: String, _ cache1h: String, _ cacheRead: String, _ output: String) -> ModelRate {
        ModelRate(
            input: Decimal(string: input) ?? 0,
            cache5m: Decimal(string: cache5m) ?? 0,
            cache1h: Decimal(string: cache1h) ?? 0,
            cacheRead: Decimal(string: cacheRead) ?? 0,
            output: Decimal(string: output) ?? 0
        )
    }
}

public enum UsageRollup {
    public static func today(entries: [TranscriptEntry], now: Date, calendar: Calendar = .current) -> (tokens: Int, cost: Decimal?, incomplete: Bool) {
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            return (0, Decimal(0), false)
        }
        return sum(entries.filter { entry in
            guard let timestamp = entry.timestamp else { return false }
            return timestamp >= start && timestamp < end
        })
    }

    public static func sum(_ entries: [TranscriptEntry]) -> (tokens: Int, cost: Decimal?, incomplete: Bool) {
        var tokens = 0
        var cost = Decimal(0)
        var priced = false
        var incomplete = false
        for entry in entries {
            guard let usage = entry.usage else { continue }
            tokens += usage.total
            if let model = entry.model, let part = ListPrices.costUSD(usage: usage, model: model) {
                cost += part
                priced = true
            } else if entry.model != nil {
                incomplete = true
            } else {
                incomplete = true
            }
        }
        return (tokens, priced ? cost : (incomplete ? nil : Decimal(0)), incomplete)
    }

    public static func burnPerHour(entries: [TranscriptEntry], now: Date, calendar: Calendar = .current) -> Double? {
        let stamped = entries.compactMap { entry -> (Date, Int)? in
            guard let timestamp = entry.timestamp, let usage = entry.usage else { return nil }
            return (timestamp, usage.total)
        }
        let calculator = BlockCalculator(calendar: calendar)
        let blocks = calculator.blocks(from: stamped.map(\.0))
        guard let block = blocks.last, now >= block.start, now < block.end else { return nil }
        let tokens = stamped.filter { $0.0 >= block.start && $0.0 < block.end }.map(\.1).reduce(0, +)
        let elapsed = max(now.timeIntervalSince(block.start), 60)
        return Double(tokens) / (elapsed / 3600)
    }
}
