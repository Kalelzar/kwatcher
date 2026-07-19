<section class="flex min-w-0 flex-1 flex-col overflow-y-auto">
  @for ($.groups) |group| {
    @html {
      <article class="flex flex-col gap-2 border-b border-zinc-800 px-6 py-5">
        <div class="flex items-center gap-3">
          <span class="rounded bg-violet-500/15 px-2 py-0.5 text-xs font-bold uppercase tracking-wide text-violet-300">SIG{{group.name}}</span>
          <code class="rounded bg-zinc-800 px-2 py-0.5 font-mono text-xs text-zinc-300">{{group.signum}}</code>
          <button hx-post="/_introspect/signal/{{$.key}}/sig/{{group.name}}/send" hx-target="#signal-pane" hx-swap="innerHTML"
            class="ml-auto rounded bg-sky-500/15 px-2 py-0.5 text-xs font-semibold text-sky-300 transition-colors hover:bg-sky-500/25">Send</button>
        </div>
    }
    @for (group.get("handlers").?) |h| {
      @html {
        <div class="flex flex-col gap-1 border-l-2 border-zinc-800 pl-4">
          <code class="font-mono text-sm text-zinc-200">{{h.id}}</code>
          <p class="text-sm font-medium text-zinc-100">{{h.summary}}</p>
          <p class="text-sm text-zinc-400">{{h.description}}</p>
        </div>
      }
    }
    @html {
      </article>
    }
  }
  @for ($.blocked) |group| {
    @html {
      <article class="flex flex-col gap-2 border-b border-zinc-800 px-6 py-5 opacity-70">
        <div class="flex items-center gap-3">
          <span class="rounded bg-zinc-700/40 px-2 py-0.5 text-xs font-bold uppercase tracking-wide text-zinc-400">SIG{{group.name}}</span>
          <code class="rounded bg-zinc-800 px-2 py-0.5 font-mono text-xs text-zinc-500">{{group.signum}}</code>
          <button disabled title="SIGKILL/SIGSTOP cannot be caught — sending is disabled"
            class="ml-auto rounded bg-zinc-700/40 px-2 py-0.5 text-xs font-semibold text-zinc-500">Send</button>
        </div>
    }
    @for (group.get("handlers").?) |h| {
      @html {
        <div class="flex flex-col gap-1 border-l-2 border-zinc-800 pl-4">
          <code class="font-mono text-sm text-zinc-400">{{h.id}}</code>
          <p class="text-sm text-zinc-500">{{h.summary}}</p>
        </div>
      }
    }
    @html {
      </article>
    }
  }
</section>
