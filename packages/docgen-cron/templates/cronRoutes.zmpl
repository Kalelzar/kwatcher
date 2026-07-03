<section class="flex min-w-0 flex-1 flex-col overflow-y-auto">
  @for ($.jobs) |job| {
    @html {
      <article class="flex flex-col gap-2 border-b border-zinc-800 px-6 py-5">
        <div class="flex items-center gap-3">
          <span class="rounded bg-violet-500/15 px-2 py-0.5 text-xs font-bold uppercase tracking-wide text-violet-300">{{job.kind}}</span>
          <code class="font-mono text-sm text-zinc-200">{{job.name}}</code>
          <code class="ml-auto rounded bg-zinc-800 px-2 py-0.5 font-mono text-xs text-zinc-300">{{job.expression}}</code>
          <button hx-post="/_introspect/cron/{{$.key}}/job/static/{{job.name}}/run" hx-target="#cron-pane" hx-swap="innerHTML"
            class="rounded bg-sky-500/15 px-2 py-0.5 text-xs font-semibold text-sky-300 transition-colors hover:bg-sky-500/25">Run</button>
          <button hx-post="/_introspect/cron/{{$.key}}/job/static/{{job.name}}/cancel" hx-target="#cron-pane" hx-swap="innerHTML"
            class="rounded bg-rose-500/15 px-2 py-0.5 text-xs font-semibold text-rose-300 transition-colors hover:bg-rose-500/25">Cancel</button>
        </div>
        <p class="text-sm font-medium text-zinc-100">{{job.summary}}</p>
        <p class="text-sm text-zinc-400">{{job.description}}</p>
    }
    @partial cronNextFire(key: $.key, name: job.name, at: job.next_fire_at, in: job.next_fire_in, delay: job.poll_delay)
    @html {
      </article>
    }
  }
  @for ($.cancelled) |job| {
    @html {
      <article class="flex flex-col gap-2 border-b border-zinc-800 px-6 py-5 opacity-70">
        <div class="flex items-center gap-3">
          <span class="rounded bg-zinc-700/40 px-2 py-0.5 text-xs font-bold uppercase tracking-wide text-zinc-400">cancelled</span>
          <code class="font-mono text-sm text-zinc-400">{{job.name}}</code>
          <code class="ml-auto rounded bg-zinc-800 px-2 py-0.5 font-mono text-xs text-zinc-500">{{job.expression}}</code>
          <button hx-post="/_introspect/cron/{{$.key}}/job/{{job.name}}/resurrect" hx-target="#cron-pane" hx-swap="innerHTML"
            class="rounded bg-emerald-500/15 px-2 py-0.5 text-xs font-semibold text-emerald-300 transition-colors hover:bg-emerald-500/25">Restore</button>
        </div>
        <p class="text-sm text-zinc-500">{{job.summary}}</p>
      </article>
    }
  }
</section>
