<section class="flex min-w-0 flex-1 flex-col overflow-y-auto" x-data="{ tab: 'queries' }">
  <nav class="flex shrink-0 items-center border-b border-zinc-700/60 px-2">
    <button hx-get="/_introspect/sqlite/{{$.key}}/queries" hx-target="#sqlite-pane" hx-swap="innerHTML"
      @click="tab = 'queries'" :class="tab === 'queries' ? 'border-sky-400 text-zinc-100' : 'border-transparent text-zinc-400 hover:text-zinc-200'"
      class="border-b-2 px-4 py-3 text-sm font-medium transition-colors">Queries</button>
    <button hx-get="/_introspect/sqlite/{{$.key}}/tables" hx-target="#sqlite-pane" hx-swap="innerHTML"
      @click="tab = 'tables'" :class="tab === 'tables' ? 'border-sky-400 text-zinc-100' : 'border-transparent text-zinc-400 hover:text-zinc-200'"
      class="border-b-2 px-4 py-3 text-sm font-medium transition-colors">Tables</button>
    <button hx-get="/_introspect/sqlite/{{$.key}}/console" hx-target="#sqlite-pane" hx-swap="innerHTML"
      @click="tab = 'console'" :class="tab === 'console' ? 'border-sky-400 text-zinc-100' : 'border-transparent text-zinc-400 hover:text-zinc-200'"
      class="border-b-2 px-4 py-3 text-sm font-medium transition-colors">Console</button>
    <button hx-get="/_introspect/sqlite/{{$.key}}/migrations" hx-target="#sqlite-pane" hx-swap="innerHTML"
      @click="tab = 'migrations'" :class="tab === 'migrations' ? 'border-sky-400 text-zinc-100' : 'border-transparent text-zinc-400 hover:text-zinc-200'"
      class="border-b-2 px-4 py-3 text-sm font-medium transition-colors">Migrations</button>
  </nav>
  <div id="sqlite-pane" class="flex min-w-0 flex-1 flex-col" hx-get="/_introspect/sqlite/{{$.key}}/queries" hx-trigger="load" hx-swap="innerHTML"></div>
</section>
