const std = @import("std");
const schema = @import("../../schema.zig");
const klib = @import("klib");

pub const ClientData = struct {
    client: schema.Client.V1,
    host: []const u8,
};

pub const ClientDataWithId = klib.meta.MergeStructs(ClientData, struct { id: []const u8 });

pub const ClientHeartbeat = struct { id: []const u8 };

pub const Status = enum {
    active,
    sleeping,
    shutdown,
    unknown,
};

pub const Powerstate = enum {
    active,
    sleeping,
    shutdown,
};

pub const RegistrationState = enum {
    unregistered,
    announcing,
    registered,
};

pub const ClientStatus = klib.meta.MergeStructs(
    ClientHeartbeat,
    struct { status: Powerstate },
);

pub const ClientAck = struct {
    client: schema.Client.V1,
    id: []const u8,
};

pub const Client = struct {
    pub const Announce = struct {
        pub const V1 = schema.Schema(
            1,
            "client.announce",
            ClientDataWithId,
        );
    };

    pub const Reannounce = struct {
        pub const Request = struct {
            pub const V1 = schema.Schema(
                1,
                "client.reannounce.request",
                struct {},
            );
        };
    };

    pub const Heartbeat = struct {
        pub const V1 = schema.Schema(
            1,
            "client.heartbeat",
            ClientHeartbeat,
        );
    };

    pub const Status = struct {
        pub const V1 = schema.Schema(
            1,
            "client.status",
            ClientStatus,
        );
    };

    pub const Ack = struct {
        pub const V1 = schema.Schema(
            1,
            "client.ack",
            ClientAck,
        );
    };
};
