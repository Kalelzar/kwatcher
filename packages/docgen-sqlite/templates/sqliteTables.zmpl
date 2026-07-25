<section class="flex min-w-0 flex-1 flex-col overflow-y-auto">
  @if ($.status == "")

  @for ($.tables) |t| {
    @html {
      <article class="border-b border-zinc-800 px-6 py-5">
        <h3 class="mb-3 font-mono text-sm font-semibold text-zinc-100">{{t.name}}</h3>
        <table class="w-full text-left text-sm">
          <thead>
            <tr class="text-xs uppercase tracking-wider text-zinc-500">
              <th class="py-1 pr-4">Column</th>
              <th class="py-1 pr-4">Affinity</th>
              <th class="py-1 pr-4">Constraints</th>
              <th class="py-1">References</th>
            </tr>
          </thead>
          <tbody>
    }
    @for (t.get("columns").?) |c| {
      @html {
            <tr class="border-t border-zinc-800/60">
              <td class="py-1.5 pr-4 font-mono text-zinc-200">{{c.name}}</td>
              <td class="py-1.5 pr-4 font-mono text-xs text-zinc-400">{{c.affinity}}</td>
              <td class="py-1.5 pr-4 text-xs text-zinc-300">{{c.constraints}}</td>
              <td class="py-1.5 font-mono text-xs text-zinc-400">{{c.fk}}</td>
            </tr>
      }
    }
    @html {
          </tbody>
        </table>
      </article>
    }
  }
  @else

  <p class="p-6 text-sm text-zinc-400">{{$.status}}</p>
  @end
</section>
