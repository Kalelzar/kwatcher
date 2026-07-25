@if ($.status == "")

<pre class="overflow-x-auto rounded-lg border border-zinc-800 bg-zinc-900 p-3 font-mono text-xs text-emerald-300"><code>{{$.output}}</code></pre>
@else

<div class="rounded-lg border border-rose-500/40 bg-rose-950/30 px-3 py-2 text-sm text-rose-300">{{$.status}}</div>
@end
