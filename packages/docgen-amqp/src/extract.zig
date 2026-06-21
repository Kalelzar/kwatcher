const std = @import("std");
const docindex = @import("kw-docindex");
const asyncapi = @import("kw-asyncapi");
const reflect = @import("kw-docschema").reflect;

const model = asyncapi.model;
const version = asyncapi.version;

const Operation = model.Operation;

/// Build a version-neutral AsyncAPI `model.Document` from an AMQP driver's routes.
///
/// `arena` should be an arena allocator: every slice the document points at is
/// allocated from it and freed in one shot when the document is no longer needed.
pub fn buildDocument(
    comptime Driver: type,
    info: model.Info,
    ver: version.AsyncApiVersion,
    doc_index: ?*const docindex.DocIndex,
    arena: std.mem.Allocator,
) !model.Document {
    var components: model.Components = .{};
    var ctx: reflect.Ctx = .{ .allocator = arena, .components = &components.schemas, .doc_index = doc_index };

    var channels: std.StringArrayHashMapUnmanaged(ChannelBuild) = .empty;
    var operations: std.ArrayListUnmanaged(Operation) = .empty;

    inline for (Driver.Routes) |R| {
        try addRoute(R, &channels, &operations, &components, &ctx, arena);
    }

    const out_channels = try arena.alloc(model.Channel, channels.count());
    for (channels.values(), 0..) |*cb, i| out_channels[i] = try cb.finish(arena);

    return .{
        .asyncapi_version = ver,
        .info = info,
        .channels = out_channels,
        .operations = try operations.toOwnedSlice(arena),
        .components = components,
    };
}

/// A channel accumulated across the routes that share its address. Routes carry
/// one message each; a channel collects every message that flows over it.
const ChannelBuild = struct {
    id: []const u8,
    address: ?[]const u8,
    exchange: ?[]const u8,
    messages: std.StringArrayHashMapUnmanaged(void) = .empty,

    fn finish(self: *ChannelBuild, arena: std.mem.Allocator) !model.Channel {
        const bindings: model.Bindings = if (self.exchange) |ex| .{ .amqp = .{
            .is = .routingKey,
            .exchange = .{ .name = ex },
        } } else .{};
        return .{
            .id = self.id,
            .address = self.address,
            .messages = try arena.dupe([]const u8, self.messages.keys()),
            .bindings = bindings,
        };
    }
};

fn addRoute(
    comptime R: type,
    channels: *std.StringArrayHashMapUnmanaged(ChannelBuild),
    operations: *std.ArrayListUnmanaged(Operation),
    components: *model.Components,
    ctx: *reflect.Ctx,
    arena: std.mem.Allocator,
) !void {
    const meta = R.meta;
    const id = comptime channelId(meta);

    const gop = try channels.getOrPut(arena, id);
    if (!gop.found_existing) gop.value_ptr.* = .{
        .id = id,
        .address = comptime channelAddress(meta),
        .exchange = comptime channelExchange(meta),
    };

    if (comptime meta.PayloadOut) |Out| {
        const name = try addMessage(Out, meta.event, components, ctx, arena);
        try gop.value_ptr.messages.put(arena, name, {});
        try operations.append(arena, try buildOperation(meta, .send, id, name, doc(ctx, meta), arena));
    }
    if (comptime meta.PayloadIn) |In| {
        const name = try addMessage(In, meta.event, components, ctx, arena);
        try gop.value_ptr.messages.put(arena, name, {});
        try operations.append(arena, try buildOperation(meta, .receive, id, name, doc(ctx, meta), arena));
    }
}

/// Reflect a payload type into the schema registry and register a message for it,
/// returning the message name. Named payloads dedupe; the schema's component name
/// doubles as the message name so two routes carrying the same type share one.
fn addMessage(
    comptime Payload: type,
    comptime event: []const u8,
    components: *model.Components,
    ctx: *reflect.Ctx,
    arena: std.mem.Allocator,
) ![]const u8 {
    const payload = try reflect.schemaFor(Payload, ctx);
    const name = if (payload.ref) |ref| basename(ref) else event;
    if (!components.messages.contains(name)) {
        try components.messages.put(arena, name, .{ .name = name, .payload = payload });
    }
    return name;
}

fn buildOperation(
    comptime meta: anytype,
    comptime action: model.Action,
    channel_id: []const u8,
    message_name: []const u8,
    summary_desc: SummaryDesc,
    arena: std.mem.Allocator,
) !Operation {
    const messages = try arena.dupe([]const u8, &.{message_name});
    return .{
        .id = comptime operationId(meta, action),
        .action = action,
        .channel_id = channel_id,
        .summary = summary_desc.summary,
        .description = summary_desc.description,
        .messages = messages,
    };
}

const SummaryDesc = struct { summary: []const u8, description: ?[]const u8 };

/// Summary and description from the handler's `///` doc comment: summary is the
/// first sentence, description the full text when it carries more. With no comment
/// the summary falls back to the event name.
fn doc(ctx: *reflect.Ctx, comptime meta: anytype) SummaryDesc {
    if (ctx.doc_index) |idx| {
        if (idx.declDoc(meta.raw)) |d| {
            const first = firstSentence(d);
            return .{ .summary = first, .description = if (d.len > first.len) d else null };
        }
    }
    return .{ .summary = meta.event, .description = null };
}

// --- channel addressing ------------------------------------------------------

/// A JSON-Pointer-safe channel key. Routes sharing an exchange + routing key share
/// a channel; unrouted routes (no address) key off the event name.
fn channelId(comptime meta: anytype) []const u8 {
    comptime {
        if (meta.exchange.len == 0) return replaceSlash(meta.event);
        if (meta.routing_key.len == 0) return replaceSlash(meta.exchange);
        return replaceSlash(meta.exchange ++ "/" ++ meta.routing_key);
    }
}

fn channelAddress(comptime meta: anytype) ?[]const u8 {
    return if (meta.routing_key.len == 0) null else meta.routing_key;
}

fn channelExchange(comptime meta: anytype) ?[]const u8 {
    return if (meta.exchange.len == 0) null else meta.exchange;
}

/// A receive route uses the event as its operation id; a reply also publishes, so
/// its send half is suffixed to stay unique. An unrouted handler is address-less
/// (no exchange) and shares its event with the publish it shadows, so its receive
/// half is suffixed too — otherwise the two operations collide on one id.
fn operationId(comptime meta: anytype, comptime action: model.Action) []const u8 {
    if (action == .send and meta.PayloadIn != null) return meta.event ++ ".reply";
    if (action == .receive and meta.exchange.len == 0) return meta.event ++ ".unrouted";
    return meta.event;
}

// --- string helpers ----------------------------------------------------------

fn basename(ref: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, ref, '/') orelse return ref;
    return ref[i + 1 ..];
}

fn replaceSlash(comptime s: []const u8) []const u8 {
    comptime {
        var out: [s.len]u8 = undefined;
        for (s, 0..) |c, i| out[i] = if (c == '/') '.' else c;
        const frozen = out;
        return &frozen;
    }
}

/// The first sentence of a doc comment: up to the first sentence-ending period (or
/// the first line break), trimmed.
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

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

// --- tests -------------------------------------------------------------------
// Fabricate route/driver types matching the shape the amqp package produces (a
// `meta` descriptor per route, gathered in `Routes`) so extraction can be
// exercised without depending on the amqp package.

const Announce = struct { id: []const u8, host: []const u8 };
const Ack = struct { id: []const u8 };

/// Mirrors `amqp.Meta` so the optional `Payload*` fields keep their `?type` typing.
const Meta = struct {
    raw: []const u8,
    event: []const u8,
    exchange: []const u8,
    routing_key: []const u8,
    queue: ?[]const u8 = null,
    PayloadIn: ?type = null,
    PayloadOut: ?type = null,
};

fn TestRoute(comptime route_meta: Meta) type {
    return struct {
        pub const meta = route_meta;
    };
}

const TestDoc = struct { doc: model.Document, arena: *std.heap.ArenaAllocator };

fn buildTestDoc(comptime Driver: type, doc_index: ?*const docindex.DocIndex) !TestDoc {
    const arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
    const d = try buildDocument(Driver, .{ .title = "t", .version = "1" }, .v3_0_0, doc_index, arena.allocator());
    return .{ .doc = d, .arena = arena };
}

fn findOp(d: model.Document, id: []const u8) ?Operation {
    for (d.operations) |op| if (std.mem.eql(u8, op.id, id)) return op;
    return null;
}

fn findChannel(d: model.Document, id: []const u8) ?model.Channel {
    for (d.channels) |ch| if (std.mem.eql(u8, ch.id, id)) return ch;
    return null;
}

test "publish becomes a send operation with an exchange-bound channel" {
    const Driver = struct {
        pub const Routes = &[_]type{TestRoute(.{
            .raw = "publish:client-announce amq.direct/client.announce",
            .event = "client-announce",
            .exchange = "amq.direct",
            .routing_key = "client.announce",
            .PayloadOut = Announce,
        })};
    };
    const r = try buildTestDoc(Driver, null);
    defer {
        r.arena.deinit();
        std.testing.allocator.destroy(r.arena);
    }

    const op = findOp(r.doc, "client-announce").?;
    try std.testing.expectEqual(model.Action.send, op.action);
    try std.testing.expectEqualStrings("amq.direct.client.announce", op.channel_id);
    try std.testing.expectEqualStrings("Announce", op.messages[0]);

    const ch = findChannel(r.doc, "amq.direct.client.announce").?;
    try std.testing.expectEqualStrings("client.announce", ch.address.?);
    try std.testing.expectEqualStrings("amq.direct", ch.bindings.amqp.?.exchange.?.name);
    try std.testing.expectEqual(asyncapi.bindings.ChannelIs.routingKey, ch.bindings.amqp.?.is.?);

    try std.testing.expect(r.doc.components.messages.contains("Announce"));
    try std.testing.expect(r.doc.components.schemas.schemas.contains("Announce"));
}

test "consume becomes a receive operation" {
    const Driver = struct {
        pub const Routes = &[_]type{TestRoute(.{
            .raw = "consume:client-ack amq.direct/client.ack",
            .event = "client-ack",
            .exchange = "amq.direct",
            .routing_key = "client.ack",
            .PayloadIn = Ack,
        })};
    };
    const r = try buildTestDoc(Driver, null);
    defer {
        r.arena.deinit();
        std.testing.allocator.destroy(r.arena);
    }

    const op = findOp(r.doc, "client-ack").?;
    try std.testing.expectEqual(model.Action.receive, op.action);
    try std.testing.expectEqualStrings("Ack", op.messages[0]);
}

test "reply yields a receive and a suffixed send on one channel" {
    const Driver = struct {
        pub const Routes = &[_]type{TestRoute(.{
            .raw = "reply:do-thing amq.direct/thing",
            .event = "do-thing",
            .exchange = "amq.direct",
            .routing_key = "thing",
            .PayloadIn = Ack,
            .PayloadOut = Announce,
        })};
    };
    const r = try buildTestDoc(Driver, null);
    defer {
        r.arena.deinit();
        std.testing.allocator.destroy(r.arena);
    }

    try std.testing.expectEqual(model.Action.send, findOp(r.doc, "do-thing.reply").?.action);
    try std.testing.expectEqual(model.Action.receive, findOp(r.doc, "do-thing").?.action);

    const ch = findChannel(r.doc, "amq.direct.thing").?;
    try std.testing.expectEqual(@as(usize, 2), ch.messages.len);
}

test "an unrouted handler sharing a publish's event gets a distinct operation id" {
    const Driver = struct {
        pub const Routes = &[_]type{
            TestRoute(.{
                .raw = "publish!:client-heartbeat amq.direct/client.heartbeat",
                .event = "client-heartbeat",
                .exchange = "amq.direct",
                .routing_key = "client.heartbeat",
                .PayloadOut = Ack,
            }),
            TestRoute(.{
                .raw = "unrouted:client-heartbeat",
                .event = "client-heartbeat",
                .exchange = "",
                .routing_key = "",
                .PayloadIn = Ack,
            }),
        };
    };
    const r = try buildTestDoc(Driver, null);
    defer {
        r.arena.deinit();
        std.testing.allocator.destroy(r.arena);
    }

    try std.testing.expectEqual(model.Action.send, findOp(r.doc, "client-heartbeat").?.action);
    try std.testing.expectEqual(model.Action.receive, findOp(r.doc, "client-heartbeat.unrouted").?.action);

    // Operation ids must be unique across the whole document.
    for (r.doc.operations, 0..) |a, i| {
        for (r.doc.operations[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.id, b.id));
        }
    }
}

test "summary and description come from the doc comment" {
    const Driver = struct {
        pub const Routes = &[_]type{TestRoute(.{
            .raw = "publish:client-announce amq.direct/client.announce",
            .event = "client-announce",
            .exchange = "amq.direct",
            .routing_key = "client.announce",
            .PayloadOut = Announce,
        })};
    };

    var index: docindex.DocIndex = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer index.deinit();
    try docindex.indexSource(std.testing.allocator, &index,
        \\/// Announce a client. Carries identity and host.
        \\pub fn @"publish:client-announce amq.direct/client.announce"() void {}
    );

    const r = try buildTestDoc(Driver, &index);
    defer {
        r.arena.deinit();
        std.testing.allocator.destroy(r.arena);
    }

    const op = findOp(r.doc, "client-announce").?;
    try std.testing.expectEqualStrings("Announce a client.", op.summary);
    try std.testing.expectEqualStrings("Announce a client. Carries identity and host.", op.description.?);
}
