@if ($.tag == "ok")
@partial head(title: "KW-IntrospectUI") {
  <sidebar class="flex h-screen w-72 shrink-0 flex-col bg-zinc-900">
    <header class="flex h-[4.5rem] shrink-0 items-center border-b border-zinc-700/60 px-4">
      <span class="text-base font-semibold leading-7 tracking-tight text-zinc-100">KW-IntrospectUI</span>
    </header>
    <div class="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto p-4">
      <span class="px-1 text-xs font-medium uppercase tracking-wider text-zinc-400">Drivers</span>
      <nav class="flex flex-col gap-0.5" hx-get="/_introspect/drivers?key={{$.key}}&kind={{$.kind}}" hx-trigger="load">
        <div class="flex items-center gap-2.5 px-3 py-2"><div class="h-7 w-7 shrink-0 animate-pulse rounded bg-zinc-700/70"></div><div class="h-3 w-28 animate-pulse rounded bg-zinc-700/70"></div></div>
        <div class="flex items-center gap-2.5 px-3 py-2"><div class="h-7 w-7 shrink-0 animate-pulse rounded bg-zinc-700/70"></div><div class="h-3 w-20 animate-pulse rounded bg-zinc-700/70"></div></div>
        <div class="flex items-center gap-2.5 px-3 py-2"><div class="h-7 w-7 shrink-0 animate-pulse rounded bg-zinc-700/70"></div><div class="h-3 w-24 animate-pulse rounded bg-zinc-700/70"></div></div>
        <div class="flex items-center gap-2.5 px-3 py-2"><div class="h-7 w-7 shrink-0 animate-pulse rounded bg-zinc-700/70"></div><div class="h-3 w-16 animate-pulse rounded bg-zinc-700/70"></div></div>
        <div class="flex items-center gap-2.5 px-3 py-2"><div class="h-7 w-7 shrink-0 animate-pulse rounded bg-zinc-700/70"></div><div class="h-3 w-24 animate-pulse rounded bg-zinc-700/70"></div></div>
      </nav>
    </div>
  </sidebar>
  <content id="content" class="flex min-h-0 flex-1 flex-col">
    <div id="kw-current-driver" data-kind="{{$.kind}}" data-key="{{$.key}}" hidden></div>
    <header class="flex h-[4.5rem] shrink-0 items-center gap-3 border-b border-zinc-700/60 bg-zinc-900 px-8">
      <h1 class="text-xl font-semibold tracking-tight text-zinc-100">{{$.key}}</h1>
      <span class="text-sm text-zinc-400">{{$.kind}}</span>
      <button hx-get="/_introspect/{{$.kind}}/{{$.key}}/view" hx-target="#view-pane" hx-swap="innerHTML"
        class="group ml-auto inline-flex items-center gap-1.5 self-center rounded-lg border border-zinc-700 px-2.5 py-1.5 text-xs font-medium text-zinc-300 transition-colors hover:bg-zinc-800 hover:text-zinc-100"
        aria-label="Reload operations" title="Reload operations">
        <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="h-4 w-4 group-[.htmx-request]:animate-spin">
          <path stroke-linecap="round" stroke-linejoin="round" d="M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0 3.181 3.183a8.25 8.25 0 0 0 13.803-3.7M4.031 9.865a8.25 8.25 0 0 1 13.803-3.7l3.181 3.182m0-4.991v4.99" />
        </svg>
        Reload
      </button>
    </header>
    <div id="view-pane" class="flex min-h-0 flex-1 border-l border-zinc-700/60 bg-zinc-950" hx-get="/_introspect/{{$.kind}}/{{$.key}}/view" hx-trigger="load"></div>
  </content>
}
@else

@partial head(title: "KW-IntrospectUI") {
  <sidebar class="flex h-screen w-72 shrink-0 flex-col bg-zinc-900">
    <header class="flex h-[4.5rem] shrink-0 items-center border-b border-zinc-700/60 px-4">
      <span class="text-base font-semibold leading-7 tracking-tight text-zinc-100">KW-IntrospectUI</span>
    </header>
    <div class="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto p-4">
      <span class="px-1 text-xs font-medium uppercase tracking-wider text-zinc-400">Drivers</span>
      <nav class="flex flex-col gap-0.5" hx-get="/_introspect/drivers" hx-trigger="load">
        <div class="flex items-center gap-2.5 px-3 py-2"><div class="h-7 w-7 shrink-0 animate-pulse rounded bg-zinc-700/70"></div><div class="h-3 w-28 animate-pulse rounded bg-zinc-700/70"></div></div>
        <div class="flex items-center gap-2.5 px-3 py-2"><div class="h-7 w-7 shrink-0 animate-pulse rounded bg-zinc-700/70"></div><div class="h-3 w-20 animate-pulse rounded bg-zinc-700/70"></div></div>
        <div class="flex items-center gap-2.5 px-3 py-2"><div class="h-7 w-7 shrink-0 animate-pulse rounded bg-zinc-700/70"></div><div class="h-3 w-24 animate-pulse rounded bg-zinc-700/70"></div></div>
      </nav>
    </div>
  </sidebar>
  <content id="content" class="flex flex-1 flex-col items-center justify-center border-l border-zinc-700/60 bg-zinc-950 p-8">
    <div class="w-full max-w-md rounded-xl border border-red-500/40 bg-red-950/40 px-6 py-5 text-center">
      <p class="text-lg font-semibold text-red-200">Unknown driver</p>
      <p class="mt-1 text-sm text-red-300/80">The requested driver could not be found.</p>
    </div>
  </content>
}
@end
