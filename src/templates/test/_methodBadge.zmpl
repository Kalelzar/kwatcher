@args method: []const u8
@zig {
    const mcls: []const u8 =
        if (std.mem.eql(u8, method, "GET")) "bg-emerald-500/15 text-emerald-300"
        else if (std.mem.eql(u8, method, "POST")) "bg-sky-500/15 text-sky-300"
        else if (std.mem.eql(u8, method, "PUT")) "bg-amber-500/15 text-amber-300"
        else if (std.mem.eql(u8, method, "PATCH")) "bg-violet-500/15 text-violet-300"
        else if (std.mem.eql(u8, method, "DELETE")) "bg-rose-500/15 text-rose-300"
        else "bg-zinc-700 text-zinc-300";
    <span class="rounded px-2 py-0.5 text-xs font-bold tracking-wide {{mcls}}">{{method}}</span>
}
