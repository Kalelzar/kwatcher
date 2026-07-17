const std = @import("std");

const Client = @import("../client/client.zig");
const AmqpClient = @import("../client/amqp_client.zig");

const BaseConfig = @import("kw-core").config.BaseConfig;
const Pool = @import("kw-core").pool.Pool;

pub const AmqpClientContext = struct {
    pub fn eql(a: Client, b: Client) bool {
        return std.mem.eql(u8, a.id(), b.id());
    }

    pub fn cancel(a: Client) !void {
        _ = a;
        // NOOP: The amqp client does not support cancellation as of this time.
    }

    pub fn deinit(a: Client) void {
        _ = a;
        // NOOP: This is just a vtable interface, free the actual underlying client later.
    }
};

const AmqpClientPool = Pool(Client, AmqpClientContext);

pub const ClientPool = struct {
    pool: AmqpClientPool,
    clients: []AmqpClient,

    pub fn init(allocator: std.mem.Allocator, configuration: *BaseConfig, pool_size: u8, timeout_ns: u64) !ClientPool {
        const buf = try allocator.alloc(AmqpClient, pool_size);
        var namebuf: [64]u8 = undefined;
        const pool = try AmqpClientPool.initPreheated(allocator, pool_size, timeout_ns);
        for (buf, 0..) |*amqp, i| {
            amqp.* = try .init(allocator, configuration, try std.fmt.bufPrint(&namebuf, "amqp-{d}", .{i}));
            pool.buffer.buffer[i] = amqp.client();
        }

        return .{
            .clients = buf,
            .pool = pool,
        };
    }

    pub fn deinit(self: *ClientPool, allocator: std.mem.Allocator) void {
        self.pool.deinit(allocator);
        for (self.clients) |*c| {
            c.deinit();
        }
        allocator.free(self.clients);
    }

    pub fn lease(self: *ClientPool) !Client {
        const client: Client = try self.leaseNow();
        const internal: *AmqpClient = @ptrCast(@alignCast(client.ptr));
        if (internal.state != .connected) {
            try client.connect();
        }

        return client;
    }

    /// Leases a client without pre-faulting the connection. Callers that
    /// route through a fault-handling wrapper (e.g. a circuit breaker)
    /// connect through that wrapper instead, so an unreachable broker
    /// engages the fallback rather than failing the lease.
    pub fn leaseNow(self: *ClientPool) !Client {
        return self.pool.lease();
    }

    pub fn release(self: *ClientPool, c: Client) !void {
        c.reset();
        try self.pool.release(c);
    }
};
