//! The arithmetic of a count: what a case's operations cost from its three runs, whether the runs
//! agree, and how the cost compares with the baseline's.
//!
//! A case runs `rounds` operations twice and `2 * rounds` once. The long run less the first short
//! run is what `rounds` operations cost, since both pay the same setup. The two short runs must
//! agree within a tenth of the room the threshold leaves, or noise alone could move the case past
//! its threshold. Costs compare per operation, by cross-multiplying counts and rounds, so the
//! verdict is exact and a baseline taken at another round count still compares.

const std = @import("std");

/// The share of the threshold's room the two short runs may disagree by: one part in ten.
pub const stability_share: u64 = 10;
/// Thousandths in a whole.
pub const per_mille_whole: u64 = 1000;

/// The totals a case's three runs counted.
pub const Totals = struct {
    short: u64,
    short_again: u64,
    long: u64,
};

/// What `rounds` operations of a case cost.
pub const Measurement = struct {
    /// Operations in the short run. The long run took twice as many.
    rounds: u64,
    /// What the long run counted past the short one.
    instructions: u64,

    pub fn per_operation(self: Measurement) f64 {
        return @as(f64, @floatFromInt(self.instructions)) / @as(f64, @floatFromInt(self.rounds));
    }
};

pub const Outcome = union(enum) {
    measured: Measurement,
    /// The two short runs disagreed by more than noise may: by this many instructions.
    unstable: u64,
    /// The long run counted fewer instructions than the short one.
    long_run_shorter,
};

/// What `rounds` operations cost, from the three totals, unless the runs disagree.
pub fn measurement_of(totals: Totals, rounds: u64, threshold_per_mille: u64) Outcome {
    if (totals.long < totals.short) return .long_run_shorter;
    const instructions = totals.long - totals.short;
    const disagreement = @max(totals.short, totals.short_again) - @min(totals.short, totals.short_again);
    const noise = @as(u128, disagreement) * per_mille_whole * stability_share;
    const room = @as(u128, instructions) * threshold_per_mille;
    if (noise > room) return .{ .unstable = disagreement };
    return .{ .measured = .{ .rounds = rounds, .instructions = instructions } };
}

pub const Verdict = enum { within, grew, shrank };

/// Whether a case's cost per operation moved past the threshold from the baseline's. A move of
/// exactly the threshold stays within it.
pub fn judge(baseline: Measurement, measured: Measurement, threshold_per_mille: u64) Verdict {
    std.debug.assert(threshold_per_mille < per_mille_whole);
    const now = @as(u128, measured.instructions) * baseline.rounds * per_mille_whole;
    const before = @as(u128, baseline.instructions) * measured.rounds;
    if (now > before * (per_mille_whole + threshold_per_mille)) return .grew;
    if (now < before * (per_mille_whole - threshold_per_mille)) return .shrank;
    return .within;
}

/// The change per operation from the baseline, in percent, for the report.
pub fn change_percent(baseline: Measurement, measured: Measurement) f64 {
    const before = baseline.per_operation();
    return (measured.per_operation() - before) / before * 100;
}

/// A threshold in thousandths, in percent, for the report.
pub fn percent_of(per_mille: u64) f64 {
    return @as(f64, @floatFromInt(per_mille)) / 10;
}

// Tests.

const testing = std.testing;

test "measurement_of takes the long run less the short one, setup cancelled" {
    const outcome = measurement_of(.{ .short = 967_268, .short_again = 967_268, .long = 1_120_268 }, 1000, 20);
    try testing.expectEqual(Measurement{ .rounds = 1000, .instructions = 153_000 }, outcome.measured);
    try testing.expectEqual(153.0, outcome.measured.per_operation());
}

test "measurement_of refuses short runs that disagree by more than a tenth of the threshold's room" {
    // The room is 153,000 * 20 / 1000 = 3,060 instructions; a tenth of it is 306.
    const at_limit = measurement_of(.{ .short = 1_000_000, .short_again = 1_000_306, .long = 1_153_000 }, 1000, 20);
    try testing.expect(at_limit == .measured);
    const past_limit = measurement_of(.{ .short = 1_000_000, .short_again = 1_000_307, .long = 1_153_000 }, 1000, 20);
    try testing.expectEqual(307, past_limit.unstable);
    const other_order = measurement_of(.{ .short = 1_000_307, .short_again = 1_000_000, .long = 1_153_307 }, 1000, 20);
    try testing.expectEqual(307, other_order.unstable);
}

test "measurement_of refuses a long run that counted less than the short one" {
    try testing.expect(measurement_of(.{ .short = 500, .short_again = 500, .long = 499 }, 1000, 20) == .long_run_shorter);
    const free = measurement_of(.{ .short = 500, .short_again = 500, .long = 500 }, 1000, 20);
    try testing.expectEqual(0, free.measured.instructions);
    try testing.expect(measurement_of(.{ .short = 500, .short_again = 501, .long = 500 }, 1000, 20) == .unstable);
}

test "judge fails a move past the threshold either way, and passes one of exactly the threshold" {
    const baseline: Measurement = .{ .rounds = 1000, .instructions = 100_000 };
    try testing.expectEqual(.within, judge(baseline, baseline, 20));
    try testing.expectEqual(.within, judge(baseline, .{ .rounds = 1000, .instructions = 102_000 }, 20));
    try testing.expectEqual(.grew, judge(baseline, .{ .rounds = 1000, .instructions = 102_001 }, 20));
    try testing.expectEqual(.within, judge(baseline, .{ .rounds = 1000, .instructions = 98_000 }, 20));
    try testing.expectEqual(.shrank, judge(baseline, .{ .rounds = 1000, .instructions = 97_999 }, 20));
}

test "judge compares per operation when the round counts differ" {
    const baseline: Measurement = .{ .rounds = 1000, .instructions = 100_000 };
    try testing.expectEqual(.within, judge(baseline, .{ .rounds = 4000, .instructions = 408_000 }, 20));
    try testing.expectEqual(.grew, judge(baseline, .{ .rounds = 4000, .instructions = 408_004 }, 20));
    try testing.expectEqual(.shrank, judge(baseline, .{ .rounds = 500, .instructions = 48_999 }, 20));
}

test "judge holds the largest counts and rounds a baseline allows without overflow" {
    const large: Measurement = .{ .rounds = 1 << 32, .instructions = std.math.maxInt(u64) };
    try testing.expectEqual(.within, judge(large, large, 999));
    try testing.expectEqual(.shrank, judge(large, .{ .rounds = 1 << 32, .instructions = 1 }, 999));
}

test "change_percent and percent_of report in percent" {
    const baseline: Measurement = .{ .rounds = 1000, .instructions = 150_000 };
    try testing.expectApproxEqAbs(4.0, change_percent(baseline, .{ .rounds = 1000, .instructions = 156_000 }), 1e-9);
    try testing.expectApproxEqAbs(-10.0, change_percent(baseline, .{ .rounds = 2000, .instructions = 270_000 }), 1e-9);
    try testing.expectEqual(2.0, percent_of(20));
    try testing.expectEqual(0.5, percent_of(5));
}
