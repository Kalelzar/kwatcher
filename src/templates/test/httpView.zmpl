<section class="flex min-w-0 flex-1 flex-col overflow-y-auto" x-data="{ sel: null }">
  @for ($.operations) |op| {
    @html {
      <article class="flex flex-col gap-2 border-b border-zinc-800 px-6 py-5" hx-get="/_introspect/http/{{$.key}}/op/{{op.id}}" hx-trigger="intersect" hx-swap="outerHTML">
        <div class="flex items-center gap-3">
    }
    @partial test/methodBadge(method: op.method)
    @html {
          <code class="font-mono text-sm text-zinc-200">{{op.path}}</code>
          <span class="ml-auto font-mono text-xs text-zinc-400">{{op.id}}</span>
        </div>
        <p class="text-sm text-zinc-300">{{op.summary}}</p>
        <div class="h-3 w-40 animate-pulse rounded bg-zinc-800"></div>
      </article>
    }
  }
</section>
<aside id="op-panel" class="flex w-[30rem] shrink-0 flex-col border-l border-zinc-700/60 bg-zinc-950">
  <div class="flex flex-1 items-center justify-center p-8 text-center text-sm text-zinc-400">
    Select an operation to see examples and try it.
  </div>
</aside>
