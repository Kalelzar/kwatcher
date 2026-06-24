const std = @import("std");
const version = @import("version.zig");
const docschema = @import("kw-docschema");

/// The JSON-Schema model nodes are shared with every other docgen backend, so they
/// live in `kw-docschema` and are re-exported here — callers keep using `model.Schema`
/// etc. unchanged. The OpenAPI-shaped nodes below (`Document`, `Operation`, …) stay
/// HTTP-specific.
pub const Schema = docschema.Schema;
pub const SchemaKind = docschema.SchemaKind;
pub const Property = docschema.Property;
pub const Components = docschema.Components;

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

/// One media type a payload can be represented as.
pub const Content = struct {
    content_type: []const u8,
    schema: Schema,
};

pub const Response = struct {
    status: u16,
    description: []const u8,
    /// Media types this response can produce. Empty means "no content" (e.g.
    /// 204/3xx). More than one entry when the route content-negotiates — e.g. a
    /// `Many`/template wrapper offering `application/json` + `text/html`.
    content: []const Content = &.{},
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
