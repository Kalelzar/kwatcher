@if ($.tag == "ok")
<article hx-get="/_introspect/http/{{$.key}}/op/{{$.operation.id}}/try" hx-target="#op-panel" hx-swap="innerHTML"
  @click="sel = '{{$.operation.id}}'" :class="sel === '{{$.operation.id}}' ? 'border-l-sky-500 bg-sky-500/10 hover:bg-sky-500/20' : 'border-l-transparent hover:bg-zinc-900/40'"
  class="flex cursor-pointer flex-col gap-4 border-b border-b-zinc-800 border-l-2 px-6 py-5 transition-colors">
  <div>
    <div class="flex items-center gap-3">
      @partial test/methodBadge(method: $.operation.method)
      <code class="font-mono text-sm text-zinc-200">{{$.operation.path}}</code>
      <span class="ml-auto font-mono text-xs text-zinc-400">{{$.operation.id}}</span>
    </div>
    <p class="mt-2 text-sm font-medium text-zinc-100">{{$.operation.summary}}</p>
    <p class="mt-0.5 text-sm text-zinc-400">{{$.operation.description}}</p>
  </div>

  @zig {
    if (zmpl.ref("operation.parameters")) |params| {
      if (params.count() > 0) {
        <div>
          <h3 class="mb-1.5 text-xs font-semibold uppercase tracking-wider text-zinc-400">Parameters</h3>
          <div class="overflow-hidden rounded-lg border border-zinc-800">
            <table class="w-full text-left text-sm">
              <thead class="bg-zinc-800 text-xs uppercase tracking-wider text-zinc-400">
                <tr><th class="px-3 py-1.5 font-medium">Name</th><th class="px-3 py-1.5 font-medium">In</th><th class="px-3 py-1.5 font-medium">Type</th><th class="px-3 py-1.5 font-medium">Required</th><th class="px-3 py-1.5 font-medium">Description</th></tr>
              </thead>
              <tbody class="divide-y divide-zinc-800">
        for (params.items(.array)) |p| {
          const name = p.getT(.string, "name") orelse "";
          const location = p.getT(.string, "location") orelse "";
          const ptype = p.getT(.string, "type") orelse "";
          const required: []const u8 = if (p.getT(.boolean, "required") orelse false) "required" else "optional";
          const description = p.getT(.string, "description") orelse "";
          <tr><td class="px-3 py-1.5 font-mono text-zinc-200">{{name}}</td><td class="px-3 py-1.5 text-zinc-400">{{location}}</td><td class="px-3 py-1.5 font-mono text-xs text-emerald-300">{{ptype}}</td><td class="px-3 py-1.5 text-zinc-400">{{required}}</td><td class="px-3 py-1.5 text-zinc-400">{{description}}</td></tr>
        }
              </tbody>
            </table>
          </div>
        </div>
      }
    }
  }

  @if ($.operation.body)
  <div>
    <h3 class="mb-1.5 text-xs font-semibold uppercase tracking-wider text-zinc-400">Request Body <span class="font-mono normal-case text-zinc-400">{{$.operation.body.content_type}}</span></h3>
    <div class="rounded-lg border border-zinc-800 bg-zinc-900 p-3">
      @zig {
        if (zmpl.ref("operation.body.fields")) |fields| {
          for (fields.items(.array)) |f| {
            const name = f.getT(.string, "name") orelse "";
            const ftype = f.getT(.string, "type") orelse "";
            const required: []const u8 = if (f.getT(.boolean, "required") orelse false) "required" else "optional";
            const description = f.getT(.string, "description") orelse "";
            <div class="flex items-baseline gap-2 py-0.5 text-sm"><code class="font-mono text-zinc-200">{{name}}</code><span class="font-mono text-xs text-emerald-300">{{ftype}}</span><span class="text-xs text-zinc-400">{{required}}</span><span class="text-zinc-400">{{description}}</span></div>
          }
        }
      }
    </div>
  </div>
  @end

  <div>
    <h3 class="mb-1.5 text-xs font-semibold uppercase tracking-wider text-zinc-400">Responses</h3>
    <div class="flex flex-col gap-1.5">
      @zig {
        if (zmpl.ref("operation.responses")) |responses| {
          for (responses.items(.array)) |r| {
            const status = r.getT(.integer, "status") orelse 0;
            const desc = r.getT(.string, "description") orelse "";
            const scls: []const u8 =
                if (status < 300) "bg-emerald-500/15 text-emerald-300"
                else if (status < 400) "bg-sky-500/15 text-sky-300"
                else if (status < 500) "bg-amber-500/15 text-amber-300"
                else "bg-rose-500/15 text-rose-300";
            <div class="flex items-center gap-3 rounded-lg border border-zinc-800 px-3 py-1.5 text-sm">
              <span class="rounded px-2 py-0.5 text-xs font-bold {{scls}}">{{status}}</span>
              <span class="text-zinc-300">{{desc}}</span>
              <span class="ml-auto flex gap-1 font-mono text-xs text-zinc-400">
            if (r.get("content_types")) |cts| {
              for (cts.items(.array)) |ct| {
                const c = ct.coerce([]const u8) catch "";
                <span>{{c}}</span>
              }
            }
              </span>
            </div>
          }
        }
      }
    </div>
  </div>
</article>
@else

<article class="border-b border-zinc-800 px-6 py-5 text-sm text-rose-300">Operation not found.</article>
@end
