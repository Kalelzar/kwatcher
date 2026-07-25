<script>
  // Run-a-named-query state (Alpine), scoped to the template that uses it. The
  // POST body is a JSON array built from the per-parameter inputs (the same
  // contract a curl user gets); the returned HTML fragment lands in the
  // per-query output slot. As an inner UI route on an auth-wrapped mount the
  // call needs the UI token (kw:introspect:token). NOTE: no backslashes here —
  // zmpl mangles JS backslash escapes.
  function kwSqliteRun(key, name) {
    return {
      loading: false,
      rendered: "",
      async run() {
        this.loading = true;
        var args = [];
        this.$root.querySelectorAll("[data-arg]").forEach(function (el) {
          args.push(el.value);
        });
        var headers = { "Content-Type": "application/json" };
        var token = sessionStorage.getItem("kw:introspect:token");
        if (token) headers["Authorization"] = "Bearer " + token;
        try {
          var res = await fetch("/_introspect/sqlite/" + key + "/query/" + name + "/run", {
            method: "POST",
            headers: headers,
            body: JSON.stringify(args),
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

<section class="flex min-w-0 flex-1 flex-col overflow-y-auto">
  @if ($.status == "")

  @for ($.with_args) |q| {
    @html {
      <article class="flex flex-col gap-2 border-b border-zinc-800 px-6 py-5" x-data="kwSqliteRun('{{$.key}}', '{{q.id}}')">
        <div class="flex items-center gap-3">
          <code class="font-mono text-sm text-zinc-200">{{q.id}}</code>
          <code class="ml-auto rounded bg-zinc-800 px-2 py-0.5 font-mono text-xs text-zinc-300">{{q.signature}}</code>
          <button x-on:click="run()" :disabled="loading"
            class="rounded bg-sky-500/15 px-2 py-0.5 text-xs font-semibold text-sky-300 transition-colors hover:bg-sky-500/25 disabled:cursor-not-allowed disabled:opacity-50">
            <span x-text="loading ? 'Running…' : 'Run'"></span>
          </button>
        </div>
        <p class="text-sm font-medium text-zinc-100">{{q.summary}}</p>
        <p class="text-sm text-zinc-400">{{q.description}}</p>
        <div class="flex flex-wrap gap-2">
    }
    @for (q.get("params").?) |p| {
      @html {
          <input data-arg placeholder="{{p.type_name}}" spellcheck="false"
            class="w-48 rounded-lg border border-zinc-700 bg-zinc-900 px-3 py-1.5 font-mono text-xs text-zinc-100 placeholder:text-zinc-600 focus:border-sky-500 focus:outline-none" />
      }
    }
    @html {
        </div>
        <div x-html="rendered"></div>
      </article>
    }
  }
  @for ($.no_args) |q| {
    @html {
      <article class="flex flex-col gap-2 border-b border-zinc-800 px-6 py-5" x-data="kwSqliteRun('{{$.key}}', '{{q.id}}')">
        <div class="flex items-center gap-3">
          <code class="font-mono text-sm text-zinc-200">{{q.id}}</code>
          <code class="ml-auto rounded bg-zinc-800 px-2 py-0.5 font-mono text-xs text-zinc-300">{{q.signature}}</code>
          <button x-on:click="run()" :disabled="loading"
            class="rounded bg-sky-500/15 px-2 py-0.5 text-xs font-semibold text-sky-300 transition-colors hover:bg-sky-500/25 disabled:cursor-not-allowed disabled:opacity-50">
            <span x-text="loading ? 'Running…' : 'Run'"></span>
          </button>
        </div>
        <p class="text-sm font-medium text-zinc-100">{{q.summary}}</p>
        <p class="text-sm text-zinc-400">{{q.description}}</p>
        <div x-html="rendered"></div>
      </article>
    }
  }
  @else

  <p class="p-6 text-sm text-zinc-400">{{$.status}}</p>
  @end
</section>
