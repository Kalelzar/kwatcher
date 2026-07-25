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

//! Emit a runtime-facing projection of each signal driver's routes into the
//! generated `manifest.zig`, so the in-app introspection UI can render them.
//!
//! Routes are grouped per signal (a signal fans out to every matching handler),
//! keeping the signal's name and number plus, per handler, the route id and the
//! doc comment (summary/description).
//!
//! The emitted Zig is self-contained — it defines its own `Signal*` types and a
//! `pub const signal_documents` literal, importing nothing — matching how the
//! manifest emits `DriverInfo`/`drivers` and the `Http*`/`Cron*` projections.

const std = @import("std");
const docindex = @import("kw-docindex");

/// Called once for the signal kind by the docgen framework, with every driver in
/// the app (we filter to signal-kind ourselves). Appends the runtime types + the
/// `signal_documents` array to the manifest writer.
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
    try writer.writeAll("pub const signal_documents: []const SignalDocument = &.{\n");

    inline for (Drivers) |Drv| {
        if (comptime std.mem.eql(u8, @tagName(Drv.kind), "signal")) {
            try emitDocument(writer, Drv, doc_index, name, version_str);
        }
    }

    try writer.writeAll("};\n");
}

const runtime_types =
    \\pub const SignalHandler = struct { id: []const u8, summary: []const u8, description: []const u8 };
    \\pub const SignalGroup = struct { name: []const u8, signum: u32, handlers: []const SignalHandler };
    \\pub const SignalDocument = struct { key: []const u8, title: []const u8, version: []const u8, signals: []const SignalGroup };
    \\
;

/// The driver's distinct signals in first-seen route order, so the pane lists
/// them in declaration order.
fn uniqueSignals(comptime Rs: []const type) []const @TypeOf(Rs[0].signum) {
    comptime {
        var seen: []const @TypeOf(Rs[0].signum) = &.{};
        for (Rs) |R| {
            const found = for (seen) |s| {
                if (s == R.signum) break true;
            } else false;
            if (!found) seen = seen ++ .{R.signum};
        }
        return seen;
    }
}

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
    try w.writeAll(", .signals = &.{\n");
    if (comptime Drv.Routes.len > 0) {
        inline for (comptime uniqueSignals(Drv.Routes)) |s| {
            try w.writeAll("        .{ .name = ");
            try emitStr(w, @tagName(s));
            try w.print(", .signum = {d}, .handlers = &.{{\n", .{@intFromEnum(s)});
            inline for (Drv.Routes) |R| {
                if (comptime R.signum == s) try emitHandler(w, R, doc_index);
            }
            try w.writeAll("        } },\n");
        }
    }
    try w.writeAll("    } },\n");
}

fn emitHandler(w: *std.Io.Writer, comptime R: type, doc_index: *const docindex.DocIndex) !void {
    var summary: []const u8 = "";
    var description: []const u8 = "";
    // The index is keyed by the full declaration name (the "SIG @identifier" fn
    // name), not the parsed route id.
    if (doc_index.declDoc(R.meta.raw)) |doc| {
        summary = firstSentence(doc);
        description = if (doc.len > summary.len) doc else "";
    }

    try w.writeAll("            .{ .id = ");
    try emitStr(w, R.id);
    try w.writeAll(", .summary = ");
    try emitStr(w, summary);
    try w.writeAll(", .description = ");
    try emitStr(w, description);
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
        "Runs on SIGINT.",
        firstSentence("Runs on SIGINT. More detail follows."),
    );
}

test "firstSentence stops at the first line break" {
    try std.testing.expectEqualStrings(
        "Line one",
        firstSentence("Line one\nLine two."),
    );
}
