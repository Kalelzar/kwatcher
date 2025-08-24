const std = @import("std");

const kwatcher = @import("kwatcher");

const Reader = kwatcher.replay.Reader(kwatcher.DurableCacheClient.Ops);
const Player = kwatcher.replay.Player;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    const path = args.next() orelse return error.MissingFile;
    var stdout_f = std.fs.File.stdin();
    var buf: [1024 * 64]u8 = undefined;
    var stdout_writer = stdout_f.writer(&buf);
    const stdout = &stdout_writer.interface;
    var lc = kwatcher.LoggingClient.init(stdout);
    defer lc.deinit();
    const client = lc.client();

    var manager = try kwatcher.replay.ReplayManager.init(allocator, path, client);
    defer manager.deinit();

    try manager.replay();
    try stdout.flush();

    //    try client.connect();

    //    var player = try Player.init(allocator, client, path);
    //    try player.read();

    //    try client.disconnect();
}
