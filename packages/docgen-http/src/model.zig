const std = @import("std");
const version = @import("version.zig");

/// A version-neutral, in-memory description of an HTTP API.
///
/// `extract.zig` builds one of these from a driver's routes and `reflect.zig`
/// fills in the schemas; a version-selected emitter (`emit/<v>.zig`) then renders
/// it. Nothing here is specific to OpenAPI 3.2 — fields are a superset of what the
/// various target versions need, and each emitter decides how to project them.
///
/// All slices/strings are owned by the allocator passed to `extract.buildDocument`
/// (typically an arena), so there is no per-node deinit.
pub const Document = struct {
    openapi_version: version.OpenApiVersion,
    info: Info,
    paths: []const PathItem,
    components: Components,
};

pub const Info = struct {
    title: []const u8,
    version: []const u8,
};

pub const PathItem = struct {
    /// Templated path, e.g. "/api/v1/users/{id}".
    path: []const u8,
    operations: []const Operation,
};

pub const Method = enum {
    get,
    head,
    post,
    put,
    delete,
    connect,
    options,
    trace,
    patch,
};

pub const Operation = struct {
    method: Method,
    operation_id: []const u8,
    summary: []const u8,
    /// From the route handler's `///` doc comment, when available.
    description: ?[]const u8 = null,
    parameters: []const Parameter,
    request_body: ?RequestBody = null,
    responses: []const Response,
};

pub const ParameterLocation = enum { path, query };

pub const Parameter = struct {
    name: []const u8,
    location: ParameterLocation,
    required: bool,
    schema: Schema,
};

pub const RequestBody = struct {
    required: bool,
    content_type: []const u8,
    schema: Schema,
};

pub const Response = struct {
    status: u16,
    description: []const u8,
    /// `null` means "no content" (e.g. 204/3xx).
    content_type: ?[]const u8 = null,
    schema: ?Schema = null,
};

pub const Components = struct {
    /// Component name -> schema, referenced as `#/components/schemas/<name>`.
    schemas: std.StringArrayHashMapUnmanaged(Schema) = .empty,
};

pub const Property = struct {
    name: []const u8,
    schema: Schema,
    /// From the field's `///` doc comment, when available.
    description: ?[]const u8 = null,
};

pub const SchemaKind = enum {
    object,
    array,
    string,
    integer,
    number,
    boolean,
    @"enum",
    one_of,
    ref,
    /// No constraints at all (`{}`) — used as a fallback for types we can't describe.
    empty,
};

/// A neutral superset schema node. Emitters read only the fields relevant to the
/// active `kind`. `nullable` is stored neutrally; each emitter chooses how to
/// represent it (3.0's `nullable: true` vs 3.1+/3.2's `type: [..., "null"]`).
pub const Schema = struct {
    kind: SchemaKind,
    nullable: bool = false,

    /// From the type's `///` doc comment, when available (set for named types).
    description: ?[]const u8 = null,

    /// JSON Schema `format` hint (e.g. "int64", "double") when known.
    format: ?[]const u8 = null,

    // kind == .object
    properties: []const Property = &.{},
    required: []const []const u8 = &.{},

    // kind == .array
    items: ?*const Schema = null,
    max_items: ?u64 = null,

    // kind == .enum
    enum_values: []const []const u8 = &.{},

    // kind == .one_of
    one_of: []const Schema = &.{},

    // kind == .ref ("#/components/schemas/<ref>")
    ref: ?[]const u8 = null,

    // numeric bounds, when known
    minimum: ?i64 = null,
    maximum: ?i64 = null,
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
