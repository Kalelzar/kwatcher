const std = @import("std");
const schema = @import("kw-core").schema;
const klib = @import("klib");

pub const ClientData = struct {
    /// Client information.
    client: schema.Client.V1,
    /// The host of the current system.
    host: []const u8,
};

pub const ClientDataWithId = klib.meta.MergeStructs(ClientData, struct {
    /// The client id.
    id: []const u8,
});

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
    /// Client info v1.
    client: schema.Client.V1,
    /// The client id.
    id: []const u8,
};

pub const Client = struct {
    pub const Announce = struct {
        /// A client announcement v1.
        /// It contains client identity needed for the registry
        /// to issue us a new id.
        pub const V1 = schema.Schema(
            1,
            "client.announce",
            ClientDataWithId,
        );
    };

    pub const Reannounce = struct {
        pub const Request = struct {
            /// A client reannouncement request v1.
            /// Empty.
            pub const V1 = schema.Schema(
                1,
                "client.reannounce.request",
                struct {},
            );
        };
    };

    pub const Heartbeat = struct {
        /// A liveliness heartbeat v1.
        /// Just an id.
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
        /// A client registry acknowledgement v1.
        /// Contains our issued id.
        pub const V1 = schema.Schema(
            1,
            "client.ack",
            ClientAck,
        );
    };
};
