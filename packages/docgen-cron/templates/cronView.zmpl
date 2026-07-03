<section class="flex min-w-0 flex-1 flex-col overflow-y-auto" x-data="{ tab: 'routes' }">
  <nav class="flex shrink-0 items-center border-b border-zinc-700/60 px-2">
    <button hx-get="/_introspect/cron/{{$.key}}/routes" hx-target="#cron-pane" hx-swap="innerHTML"
      @click="tab = 'routes'" :class="tab === 'routes' ? 'border-sky-400 text-zinc-100' : 'border-transparent text-zinc-400 hover:text-zinc-200'"
      class="border-b-2 px-4 py-3 text-sm font-medium transition-colors">Routes</button>
    <button hx-get="/_introspect/cron/{{$.key}}/timers" hx-target="#cron-pane" hx-swap="innerHTML"
      @click="tab = 'timers'" :class="tab === 'timers' ? 'border-sky-400 text-zinc-100' : 'border-transparent text-zinc-400 hover:text-zinc-200'"
      class="border-b-2 px-4 py-3 text-sm font-medium transition-colors">Timers</button>
  </nav>
  <div id="cron-pane" class="flex min-w-0 flex-1 flex-col" hx-get="/_introspect/cron/{{$.key}}/routes" hx-trigger="load" hx-swap="innerHTML"></div>
</section>
