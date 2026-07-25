@if ($.status == "")

@if ($.show_table == "yes")

<div class="overflow-x-auto rounded-lg border border-zinc-800">
  <table class="w-full text-left text-sm">
    <thead>
      <tr class="bg-zinc-900 text-xs uppercase tracking-wider text-zinc-500">
      @for ($.columns) |c| {
        @html {
        <th class="px-3 py-2 font-mono">{{c.name}}</th>
        }
      }
      </tr>
    </thead>
    <tbody>
    @for ($.rows) |row| {
      @html {
      <tr class="border-t border-zinc-800/60">
      }
      @for (row.get("cells").?) |cell| {
        @html {
        <td class="px-3 py-1.5 font-mono text-xs text-zinc-300">{{cell.value}}</td>
        }
      }
      @html {
      </tr>
      }
    }
    </tbody>
  </table>
</div>
@end

<p class="pt-2 text-xs text-zinc-500">{{$.note}}</p>
@else

<div class="rounded-lg border border-rose-500/40 bg-rose-950/30 px-3 py-2 text-sm text-rose-300">{{$.status}}</div>
@end
