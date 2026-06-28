@if ($.tag == "ok")
<nav class="flex shrink-0 items-center border-b border-zinc-700/60 px-2">
  <button hx-get="/_introspect/http/{{$.key}}/op/{{$.operation.id}}/examples" hx-target="#op-panel" hx-swap="innerHTML"
    class="border-b-2 border-sky-400 px-4 py-3 text-sm font-medium text-zinc-100">Examples</button>
  <button hx-get="/_introspect/http/{{$.key}}/op/{{$.operation.id}}/try" hx-target="#op-panel" hx-swap="innerHTML"
    class="border-b-2 border-transparent px-4 py-3 text-sm font-medium text-zinc-400 transition-colors hover:text-zinc-200">Try it</button>
  <span class="ml-auto self-center pr-2 font-mono text-xs text-zinc-400">{{$.operation.method}} {{$.operation.path}}</span>
</nav>
<div class="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto p-4">
  @if ($.operation.request_example)
  <section class="flex flex-col gap-1.5">
    <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">Example request <span class="font-mono normal-case text-zinc-500">{{$.operation.request_example.content_type}}</span></h3>
    @partial viewJson(body: $.operation.request_example.body)
  </section>
  @end

  @for ($.operation.responses) |r| {
    @for (r.get("examples").?) |ex| {
@html RESPEX
    <section class="flex flex-col gap-1.5">
      <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">Response {{r.status}} <span class="font-mono normal-case text-zinc-500">{{ex.content_type}}</span></h3>
      @partial viewJson(body: ex.body)
    </section>
RESPEX
    }
  }
</div>
@else

<div class="flex flex-1 items-center justify-center p-8 text-center text-sm text-rose-300">Operation not found.</div>
@end
