<section class="flex min-w-0 flex-1 flex-col gap-5 overflow-y-auto p-6">
  <div>
    <h3 class="mb-2 text-xs font-semibold uppercase tracking-wider text-zinc-400">Committed migrations</h3>
    @if ($.committed_note == "")

    <ul class="flex flex-col gap-1">
    @for ($.committed) |m| {
      @html {
      <li><code class="font-mono text-sm text-zinc-200">{{m.version}}</code></li>
      }
    }
    </ul>
    @else

    <p class="text-sm text-zinc-400">{{$.committed_note}}</p>
    @end
  </div>
  <div class="flex flex-col gap-2">
    <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">Candidate migration</h3>
    <p class="text-sm text-zinc-400">{{$.candidate_note}}</p>
    @if ($.show_candidate == "yes")

    <h4 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">up</h4>
    <pre class="overflow-x-auto rounded-lg border border-zinc-800 bg-zinc-900 p-3 font-mono text-xs text-zinc-300"><code>{{$.candidate_up}}</code></pre>
    <h4 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">down</h4>
    <pre class="overflow-x-auto rounded-lg border border-zinc-800 bg-zinc-900 p-3 font-mono text-xs text-zinc-300"><code>{{$.candidate_down}}</code></pre>
    @end
  </div>
</section>
