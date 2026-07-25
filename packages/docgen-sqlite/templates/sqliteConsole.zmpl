<script>
  // SQL console state (Alpine), scoped to the template that uses it. Sends
  // {"sql": "..."} as JSON — the exec endpoint is a plain REST route, equally
  // curl-able — and drops the returned HTML fragment below the form. As an
  // inner UI route on an auth-wrapped mount the call needs the UI token
  // (kw:introspect:token). The typed statement is kept in sessionStorage
  // (per driver key) because switching tabs htmx-swaps this pane away —
  // Alpine state dies with it. NOTE: no backslashes here — zmpl mangles JS
  // backslash escapes.
  function kwSqliteConsole(key) {
    var store = "kw:sqlite:console:" + key;
    return {
      loading: false,
      sql: sessionStorage.getItem(store) || "",
      rendered: "",
      persist() {
        sessionStorage.setItem(store, this.sql);
      },
      async exec() {
        if (!this.sql.trim()) return;
        this.loading = true;
        var headers = { "Content-Type": "application/json" };
        var token = sessionStorage.getItem("kw:introspect:token");
        if (token) headers["Authorization"] = "Bearer " + token;
        try {
          var res = await fetch("/_introspect/sqlite/" + key + "/console/exec", {
            method: "POST",
            headers: headers,
            body: JSON.stringify({ sql: this.sql }),
          });
          this.rendered = await res.text();
        } catch (err) {
          this.rendered = "<p class='text-sm text-rose-300'>" + String(err) + "</p>";
        }
        this.loading = false;
      },
    };
  }
</script>

<section class="flex min-w-0 flex-1 flex-col gap-3 overflow-y-auto p-6" x-data="kwSqliteConsole('{{$.key}}')">
  <textarea x-model="sql" rows="5" spellcheck="false" @input="persist()" @keydown.ctrl.enter="exec()"
    placeholder="SELECT … — one statement per run; the connection is shared with the application"
    class="rounded-lg border border-zinc-700 bg-zinc-900 px-3 py-2 font-mono text-sm text-zinc-100 placeholder:text-zinc-600 focus:border-sky-500 focus:outline-none"></textarea>
  <button @click="exec()" :disabled="loading"
    class="flex items-center gap-2 self-start rounded-lg bg-sky-600 px-4 py-2 text-sm font-semibold text-white transition-colors hover:bg-sky-500 disabled:cursor-not-allowed disabled:opacity-50">
    <span style="display:none" x-show="loading" class="h-4 w-4 animate-spin rounded-full border-2 border-white/40 border-t-white"></span>
    <span x-text="loading ? 'Executing…' : 'Execute'"></span>
  </button>
  <div x-html="rendered"></div>
</section>
