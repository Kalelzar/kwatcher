@partial head(title: "KW-IntrospectUI — Login") {
  <content class="flex flex-1 flex-col items-center justify-center p-8"
           hx-get="/_introspect/login/card" hx-trigger="load">
    <div class="w-full max-w-md rounded-xl border border-zinc-800 bg-zinc-900 p-6">
      <div class="h-5 w-48 animate-pulse rounded bg-zinc-700/70"></div>
      <div class="mt-3 h-3 w-64 animate-pulse rounded bg-zinc-700/70"></div>
      <div class="mt-5 h-10 w-full animate-pulse rounded-lg bg-zinc-700/70"></div>
    </div>
  </content>
}
