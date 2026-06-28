@partial test/head(title: $.title) {
  <script>
    location.replace("/_introspect/" + (localStorage.getItem("kw:last-driver") || "internal/internal"));
  </script>
  <content id="content" class="flex flex-1 flex-col items-center justify-center gap-3 p-8">
    <div class="h-8 w-8 animate-spin rounded-full border-2 border-zinc-600 border-t-sky-400" role="status" aria-label="Loading"></div>
    <p class="text-sm text-zinc-400">Loading…</p>
  </content>
}
