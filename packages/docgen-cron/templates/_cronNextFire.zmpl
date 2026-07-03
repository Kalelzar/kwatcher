@args key: []const u8, name: []const u8, at: []const u8, in: []const u8, delay: []const u8
<div hx-get="/_introspect/cron/{{key}}/job/{{name}}/next" hx-trigger="load delay:{{delay}}s" hx-swap="outerHTML" class="text-xs text-zinc-400">
  Next fire: <span class="font-mono text-zinc-200">{{at}}</span> <span class="text-zinc-500">(in {{in}})</span>
</div>
