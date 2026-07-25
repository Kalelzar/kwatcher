// This file is part of the kwatcher project.
//
// Copyright (C) 2025-2026 Borislav Atanasov
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, version 3 of the License only.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
// more details.
//
// You should have received a copy of the GNU General Public License along
// with this program. If not, see <https://www.gnu.org/licenses/>.

//! Emit a runtime-facing projection of each cron driver's static jobs into the
//! generated `manifest.zig`, so the in-app introspection UI can render them.
//!
//! Per job we keep the name, the raw cron expression (display), the doc comment
//! (summary/description), and the evaluated schedule bitmasks — the masks are what
//! `cron.calcNext` consumes, so the UI can compute real next-fire times at runtime
//! without a runtime cron parser (the DSL parser is comptime-only).
//!
//! The emitted Zig is self-contained — it defines its own `Cron*` types and a
//! `pub const cron_documents` literal, importing nothing — matching how the manifest
//! emits `DriverInfo`/`drivers` and the `Http*` projection.

const std = @import("std");
const docindex = @import("kw-docindex");

/// Called once for the cron kind by the docgen framework, with every driver in the
/// app (we filter to cron-kind ourselves). Appends the runtime types + the
/// `cron_documents` array to the manifest writer.
pub fn emitRuntime(
    comptime Drivers: []const type,
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    doc_index: *const docindex.DocIndex,
    name: []const u8,
    version_str: []const u8,
) !void {
    _ = allocator;

    try writer.writeAll(runtime_types);
    try writer.writeAll("pub const cron_documents: []const CronDocument = &.{\n");

    inline for (Drivers) |Drv| {
        if (comptime std.mem.eql(u8, @tagName(Drv.kind), "cron")) {
            try emitDocument(writer, Drv, doc_index, name, version_str);
        }
    }

    try writer.writeAll("};\n");
}

const runtime_types =
    \\pub const CronSchedule = struct { seconds: u60, minutes: u60, hours: u24, days_of_month: u31, months: u12, days_of_week: u8 };
    \\pub const CronJob = struct {
    \\    name: []const u8,
    \\    expression: []const u8,
    \\    summary: []const u8,
    \\    description: []const u8,
    \\    schedule: CronSchedule,
    \\};
    \\pub const CronDocument = struct { key: []const u8, title: []const u8, version: []const u8, jobs: []const CronJob };
    \\
;

fn emitDocument(
    w: *std.Io.Writer,
    comptime Drv: type,
    doc_index: *const docindex.DocIndex,
    title: []const u8,
    version: []const u8,
) !void {
    try w.writeAll("    .{ .key = ");
    try emitStr(w, @tagName(Drv.key));
    try w.writeAll(", .title = ");
    try emitStr(w, title);
    try w.writeAll(", .version = ");
    try emitStr(w, version);
    try w.writeAll(", .jobs = &.{\n");
    inline for (Drv.Routes) |R| {
        try emitJob(w, R, doc_index);
    }
    try w.writeAll("    } },\n");
}

fn emitJob(w: *std.Io.Writer, comptime R: type, doc_index: *const docindex.DocIndex) !void {
    var summary: []const u8 = "";
    var description: []const u8 = "";
    // The index is keyed by the full declaration name (the fn name carrying the
    // cron DSL), not the parsed job name.
    if (doc_index.declDoc(R.meta.raw)) |doc| {
        summary = firstSentence(doc);
        description = if (doc.len > summary.len) doc else "";
    }

    try w.writeAll("        .{ .name = ");
    try emitStr(w, R.id);
    try w.writeAll(", .expression = ");
    try emitStr(w, R.meta.expression);
    try w.writeAll(", .summary = ");
    try emitStr(w, summary);
    try w.writeAll(", .description = ");
    try emitStr(w, description);
    const s = R.schedule;
    try w.print(
        ", .schedule = .{{ .seconds = {d}, .minutes = {d}, .hours = {d}, .days_of_month = {d}, .months = {d}, .days_of_week = {d} }}",
        .{ s.seconds, s.minutes, s.hours, s.daysOfMonth, s.months, s.daysOfWeek },
    );
    try w.writeAll(" },\n");
}

/// The first sentence of a doc comment: up to the first sentence-ending period (or
/// the first line break), trimmed. Used as the short `summary`.
fn firstSentence(text: []const u8) []const u8 {
    var end = text.len;
    if (std.mem.indexOfScalar(u8, text, '\n')) |nl| end = nl;
    var i: usize = 0;
    while (i < end) : (i += 1) {
        if (text[i] == '.') {
            const after = i + 1;
            if (after >= end or text[after] == ' ') {
                end = after;
                break;
            }
        }
    }
    return std.mem.trimRight(u8, text[0..end], " \t");
}

/// Write `s` as a Zig string literal (with surrounding quotes), escaping the bytes
/// that would break out of the literal.
fn emitStr(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    try std.zig.stringEscape(s, w);
    try w.writeByte('"');
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

test "firstSentence stops at the first period" {
    try std.testing.expectEqualStrings(
        "Triggers every 5 seconds.",
        firstSentence("Triggers every 5 seconds. More detail follows."),
    );
}

test "firstSentence stops at the first line break" {
    try std.testing.expectEqualStrings(
        "Line one",
        firstSentence("Line one\nLine two."),
    );
}
