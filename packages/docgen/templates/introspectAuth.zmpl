@partial head(title: "KW-IntrospectUI — Auth") {
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
    <div class="shrink-0 border-t border-zinc-700/60 p-4">
      <a href="/_introspect/auth" aria-current="page"
         class="flex items-center gap-2.5 rounded-lg px-3 py-2 text-sm text-zinc-300 transition-colors hover:bg-zinc-700/50 hover:text-zinc-100 aria-[current=page]:bg-zinc-700/70 aria-[current=page]:font-medium aria-[current=page]:text-sky-300 aria-[current=page]:ring-1 aria-[current=page]:ring-inset aria-[current=page]:ring-sky-500/50">
        <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="h-4 w-4">
          <path stroke-linecap="round" stroke-linejoin="round" d="M16.5 10.5V6.75a4.5 4.5 0 1 0-9 0v3.75m-.75 11.25h10.5a2.25 2.25 0 0 0 2.25-2.25v-6.75a2.25 2.25 0 0 0-2.25-2.25H6.75a2.25 2.25 0 0 0-2.25 2.25v6.75a2.25 2.25 0 0 0 2.25 2.25Z" />
        </svg>
        Auth
      </a>
    </div>
  </sidebar>
  <content id="content" class="flex min-h-0 flex-1 flex-col">
    <header class="flex h-[4.5rem] shrink-0 items-center gap-3 border-b border-zinc-700/60 bg-zinc-900 px-8">
      <h1 class="text-xl font-semibold tracking-tight text-zinc-100">Auth</h1>
      <span class="text-sm text-zinc-400">tokens attached to Try-it requests</span>
    </header>
    <div class="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto border-l border-zinc-700/60 bg-zinc-950 p-8"
         hx-get="/_introspect/auth/schemes" hx-trigger="load">
      <div class="mx-auto w-full max-w-xl rounded-xl border border-zinc-800 bg-zinc-900 p-5">
        <div class="h-4 w-32 animate-pulse rounded bg-zinc-700/70"></div>
        <div class="mt-3 h-3 w-64 animate-pulse rounded bg-zinc-700/70"></div>
        <div class="mt-4 h-9 w-full animate-pulse rounded-lg bg-zinc-700/70"></div>
      </div>
    </div>
  </content>
}
