//! Pre-built signal routes shipped with the driver.
//!
//! Concatenate them into your signal driver's route set to terminate the
//! runtime gracefully on SIGINT/SIGTERM:
//!
//!     .routes(signal.From(MySignals) ++ signal.From(signal.default.Shutdown))
//!
//! Each handler schedules an internal shutdown through the type-erased
//! `InternalSchedulerShim`, which the runtime registers automatically — so this
//! stays agnostic of the concrete (end-user-assembled) driver set.

const dep = @import("kw-core").deps;
const InternalSchedulerShim = @import("kw-core").scheduler.InternalSchedulerShim;
const SignalInfo = @import("signal.zig").SignalInfo;

pub const Shutdown = struct {
    pub fn @"INT @shutdown-int"(_: SignalInfo, inj: *dep.DepCtx) !void {
        const scheduler = try inj.require(InternalSchedulerShim);
        try scheduler.shutdown(.{ .inj = inj });
    }

    pub fn @"TERM @shutdown-term"(_: SignalInfo, inj: *dep.DepCtx) !void {
        const scheduler = try inj.require(InternalSchedulerShim);
        try scheduler.shutdown(.{ .inj = inj });
    }
};
