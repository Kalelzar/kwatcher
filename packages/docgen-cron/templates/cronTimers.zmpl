<section hx-get="/_introspect/cron/{{$.key}}/timers" hx-trigger="load delay:{{$.refresh_delay}}s" hx-swap="outerHTML" class="flex min-w-0 flex-1 flex-col overflow-y-auto">
  @if ($.status == "")

  @for ($.timers) |job| {
    @html {
      <article class="flex flex-col gap-2 border-b border-zinc-800 px-6 py-5">
        <div class="flex items-center gap-3">
          <span class="rounded bg-amber-500/15 px-2 py-0.5 text-xs font-bold uppercase tracking-wide text-amber-300">{{job.kind}}</span>
          <code class="font-mono text-sm text-zinc-200">{{job.name}}</code>
          <code class="ml-auto rounded bg-zinc-800 px-2 py-0.5 font-mono text-xs text-zinc-300">{{job.expression}}</code>
          <button hx-post="/_introspect/cron/{{$.key}}/job/dynamic/{{job.name}}/run" hx-target="#cron-pane" hx-swap="innerHTML"
            class="rounded bg-sky-500/15 px-2 py-0.5 text-xs font-semibold text-sky-300 transition-colors hover:bg-sky-500/25">Run</button>
          <button hx-post="/_introspect/cron/{{$.key}}/job/dynamic/{{job.name}}/cancel" hx-target="#cron-pane" hx-swap="innerHTML"
            class="rounded bg-rose-500/15 px-2 py-0.5 text-xs font-semibold text-rose-300 transition-colors hover:bg-rose-500/25">Cancel</button>
        </div>
        <p class="text-sm text-zinc-300">{{job.summary}}</p>
        <div class="text-xs text-zinc-400">
          Fires: <span class="font-mono text-zinc-200">{{job.next_fire_at}}</span> <span class="text-zinc-500">(in {{job.next_fire_in}})</span>
        </div>
      </article>
    }
  }
  @else

  <p class="p-6 text-sm text-zinc-400">{{$.status}}</p>
  @end
</section>
