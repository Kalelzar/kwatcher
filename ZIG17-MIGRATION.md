# Migrating a kwatcher application to Zig 0.17 / kwatcher `zig17`

Audience: an agent porting an application that depends on the `kw-*` packages
(kwatcher-afk-v2, pushway, kw-ide, the KOReader relay, ...) from the Zig 0.15.2
line to the `zig17` branch. Read the official 0.16 and 0.17 release notes once;
this file only covers what this framework now expects from you.

## 0. Toolchain and build graph

- `minimum_zig_version = "0.17.0"` in every `build.zig.zon`.
- Dependencies that moved: httpz `e8272bf`, zqlite `865223b` and metrics.zig `3676413`
  (all "zig 0.17" commits). `-Dmetrics` works again; without it `core.metrics` is a
  no-op shim with the same API. `core.metrics.initialize` and `v1` now take an `io`.
  `uuid` is gone from `kw-amqp`.
- klib (`abf93da`, Kalelzar/klib master) and zmpl (`143dab1`, Kalelzar/zmpl main)
  are published for 0.17 and pinned by url+hash; no `--fork` flags are needed.
  zmpl vendors its zmd and zul (0.17 fixes) as path dependencies and builds the
  jetcommon module from source with its own zul, so there is no jetcommon fork.
  If you ever need to test an unpublished dependency: `zig build --fork=<checkout>`
  matches by package name + fingerprint, but cannot carry path dependencies.
- Build script API (`build.zig`): `b.args` -> `run.addPassthruArgs()`;
  `addFmt(.{ .paths = b.pathList(&.{...}) })`; `b.build_root.handle.access(p)` ->
  `b.root.access(b.graph.io, p, .{})`; `b.pathFromRoot(p)` ->
  `b.root.joinString(b.allocator, p)`; `.Debug` -> `.debug`;
  `std.builtin.OptimizeMode` -> `std.lang.Optimize`. Anything your build script reads
  from disk at configure time must be declared with `b.dependOnFileMetadata` /
  `b.dependOnDirectoryContents`, otherwise the cached configure phase goes stale.
- Every fetched package's `build.zig` is compiled into one configurer process:
  a single 0.15-era dependency anywhere in the graph breaks configuration.

## 1. The application entry point

```zig
pub fn main(init: std.process.Init) !void {
    // init.gpa: leak-checked in Debug; init.io: the default Io.Threaded;
    // init.environ_map: the only way to read the environment now.
    try juicyMain(init.gpa, init.io, init.environ_map);
}

fn juicyMain(backing: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) !void {
    var persistent = core.mem.PersistentAllocator.init(io, backing);
    ...
    const conf = try core.config.findConfigFile(Config, arena, io, environ, "myapp") orelse ...;
    const deps = core.deps.DependencyContainer(Ctx).new(io, drivers.drivers, allocator)...;
    var server = try kwatcher.server.Server(@TypeOf(deps), drivers.drivers)
        .init(io, environ, root_allocator, deps, workers);
    try server.start();
}
```

Drop the GeneralPurposeAllocator / `detectLeaks` dance; `init.gpa` already does it.
There is no `std.process.getEnvVarOwned`, `argsAlloc`, `std.crypto.random`,
`std.time.timestamp()` or `std.fs.cwd()`; everything goes through `io` or `environ`.

## 2. Io is a dependency like the allocator

The server registers two `.all` statics: `core.IoCtx` (provides `std.Io`) and
`core.EnvCtx` (provides `*const std.process.Environ.Map`). Route handlers get them
the same way they get any dependency:

```zig
pub fn @"GET /now @now"(_: http.data.Request(null), io: std.Io) !Payload {
    const now = std.Io.Clock.real.now(io).toSeconds();
    ...
}
// or, in the rare places that already hold a DepCtx:
const io = try inj.require(std.Io);
```

Clocks: `std.Io.Clock.real` (wall), `.awake` (monotonic, what cron and timeouts
use), `.boot` (cache TTLs). `Timestamp.toMilliseconds()` returns `i96`; cast.
Randomness: `io.random(buf)` / `io.randomSecure(buf)`. Sleeping:
`io.sleep(.fromMilliseconds(n), .awake)`. Files: `std.Io.Dir.cwd().openFile(io, ...)`,
`readFileAlloc(io, path, gpa, .limited(n))` (returns `StreamTooLong` instead of
truncating). Current directory: `std.process.currentPath(io, &buf)` (never
`Dir.cwd().realPath`).

## 3. Writing a driver or touching the runtime contract

- Handler construction: `init(io: std.Io, ...)` params are auto-filled by DI
  (`io` and `environ` are visible before any driver is constructed).
- Listener fan-out: `pub fn watch(self, io: std.Io, group: *std.Io.Group, deps: anytype,
  allocator: TaggedAllocator) anyerror!void` and spawn every long-lived loop with
  `try group.concurrent(io, fn, args)`. Never `async`: past `Io.Threaded`'s async
  limit (cpu count minus one) an `async` task runs inline and stalls the fan-out.
  `concurrent` needs a non-generic function; if your loop takes `deps: anytype`,
  bind the type in a local wrapper struct (see `packages/amqp/src/amqp.zig`).
- Schedulers reach the Io through `self.parent.io`.
- Queue API: `queue.push(io, ev) Cancelable!*T`, `pushUncancelable(io, ev)`,
  `tryPush(io, ev, timeout_ns)`, `pop(io) Cancelable!T`, `tryPop(io, timeout_ns) ?T`.
- Every blocking call can now return `error.Canceled`. A loop that sees it must
  leave, never retry. Locks: `try m.lock(io)` on request paths,
  `m.lockUncancelable(io)` in deinit/defer paths; never `catch {}` a lock.
- `std.Thread.{Mutex,Condition,Semaphore,Pool,WaitGroup}` no longer exist. Use
  `std.Io.Mutex` / `Io.Condition` / `Io.Semaphore`, or `core.sync.FutexSemaphore`
  (hot paths) and `core.sync.RecursiveMutex` (re-entrant C-client code).
- Teardown relies on static declaration order matching registration order; add
  new server statics at the end of both.
- The MPMC queue is `core.queue.StaticStrictWith(T, StrictOptions)`; `StaticStrict(T)`
  is the default knobs and `StaticStrictHeader(T, Header)` only remains as a
  compatibility spelling (the header word is gone, `Occupancy` is always `u32`).
  Knobs and the order to turn them are documented on `StrictOptions` in
  `packages/core/src/utils/queue.zig`: capacity, then `consumer_spin` (default 32;
  0 for idle daemons such as a 1:1 publisher/consumer pair, 256 for busy servers
  that care about handoff latency), leave `lazy_wake` on and `producer_spin` at 0.
  Cost of the new shape: 512 bytes per queue instance (four padded cache lines)
  instead of ~64, same 4 bytes per slot; no measurable idle CPU at the default.

## 4. API changes you will hit in app code

| 0.15 | zig17 |
|---|---|
| `std.meta.fields(T)`, `@typeInfo(T).@"struct".fields`, `.@"fn".params`, `.@"enum".fields` | `core.meta.fields(T)`, `core.meta.params(F)`, `core.meta.enumFields(E)` (struct-of-arrays underneath) |
| `@Type(.{ .@"enum" = ... })` etc. | `@Enum(Tag, .exhaustive, &names, &values)`, `@Struct(.auto, null, &names, &types, &attrs)`, `@Union(...)`, `@EnumLiteral()`; values typed as the tag int; empty enums need a `noreturn` tag |
| `std.testing.refAllDeclsRecursive` | `core.meta.refAllDeclsRecursive` (or `klib.testing`) |
| `std.ArrayList(T){}` | `.empty`; `ArrayList.writer()` is gone (`list.print(gpa, ...)` / `Io.Writer.Allocating`) |
| `"x" ** n`, `[_]T{v} ** n` | `@splat` / typed arrays |
| `std.mem.indexOf*`, `trimLeft/Right`, `std.fmt.allocPrint(gpa, ...)` | `find*`, `trimStart/End`, `gpa.print(...)` |
| `std.builtin` | `std.lang` (`std.builtin` is an alias, but the sweep used `std.lang`) |
| `std.zon.parse.fromSlice(T, gpa, src, null, .{})` | `fromSlice(T, .{ .gpa, .arena, .source, .diagnostics = &diag })` |
| http formatters `write(self, writer, res)` | `write(self, io, writer, res)`; `ErrorHandler.preQueue/postQueue(io, e, req, res)` |
| `kw_config.env.expand(T, alloc, value)` | `expand(T, alloc, environ, value)` |
| `kwev.KWEV.init(name, len)` / `finalize(fs)` / `deinit()` | `init(io, name, len)` / `finalize(io, fs)` / `deinit(io)`; `Recorder.initPinned(&rec, io, ...)` |
| `AmqpClient.init(allocator, cfg, name)`, registries `.init(allocator)` | `.init(io, allocator, ...)`; AMQP static factories take `io: std.Io` |
| `protocol.secret.registry.get(id)` / `getOrRequest(alloc, ...)` | `get(io, id)` / `getOrRequest(io, alloc, ...)` |
| `httpz.Config.AddressConfig{ .addr = std.net.Address }` | `httpz.Config.Address{ .ip = std.Io.net.IpAddress }` / `.unix`; `Server.init(io, alloc, cfg, handler)` |

Comptime hygiene the 0.16 rules now enforce: a route list or driver built in a
test body must be `comptime From(...)` / `comptime Driver.new(...)` (pointers to
comptime-only values are runtime values); `comptime var` locals must be copied into
a `const` before returning a slice of them; `@hasDecl` only sees `pub` decls, so
every protocol opt-in (`release`, `deconstruct`, `accepts`, ...) must be `pub`.

## 5. Tests

- `std.testing.io` is the Io. Any test hub that resolves routes needs an Io
  provider: add `io: std.Io = std.testing.io,` to the test context struct (or
  register a `core.IoCtx`), otherwise you get "Dependency not found: Io".
- The 0.17 test runner fails a test that emits `log.err`; use `log.warn` for
  expected failure paths under test.
- `std.testing.allocator` never resizes in place; tests asserting in-place growth
  need `std.heap.page_allocator`.
- `tmpDir` and friends take `std.testing.io`.

## 6. Behaviour changes to re-validate in your app

1. Cancellation: `error.Canceled` joins every blocking call's error set; your
   handlers are `anyerror!void`, so it flows out silently unless you log it.
2. Shutdown stays cooperative (`stop()` + poison events). `Io.Threaded` cancels a
   blocked thread with SIGIO and installs SIGIO/SIGPIPE handlers of its own; if you
   mask or wait on signals yourself (the signal driver does), test shutdown.
3. `readFileAlloc(..., .limited(n))` errors instead of truncating.
4. No global environment: `Init.environ_map` is read-only after `main` starts.
5. `ArenaAllocator` is thread-safe; `ThreadSafeAllocator` is gone.
6. Messages published without an explicit `correlation_id` no longer carry an
   auto-generated UUIDv7 in the AMQP property (the u256 CorrelationID stamped at
   dispatch is the real trace identity).
7. `HostName.fromUri` validates hosts that `Uri.getHost` accepted.
8. Zero overlap with `Io.Evented`: it does not compile in stock 0.17.0 and crashes
   on any Io call from a foreign thread (httpz's pool). Stay on `Io.Threaded`.

## 7. Checklist

- [ ] zon versions, dep pins, `--fork` wrapper, build script API
- [ ] `main(init)`; `Server.init(io, environ, ...)`; DI hub `.new(io, ...)`
- [ ] every `std.Thread.*` sync primitive, `std.time.*Timestamp`, `std.fs.*`,
      `std.crypto.random`, `getEnvVarOwned`, `std.net.*` replaced
- [ ] every custom driver: `init(io, ...)`, `watch(io, group, ...)`, queue calls take `io`
- [ ] reflection through `core.meta`, `@Type` rewritten, `.empty`, `@splat`
- [ ] test contexts provide `io`; `comptime` at route-builder call sites in tests
- [ ] `zig fmt --check`, `zig build test` per package, a real run with Ctrl-C drain
