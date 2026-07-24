<script>
  // Per-scheme token card. Tokens live in sessionStorage under
  // kw:auth:token:<scheme> — the same key the Try-it form reads. This is a
  // slot-free htmx fragment, so a real script is safe here (unlike the shell
  // page, whose partial slot corrupts braced JS). NOTE: no backslashes in
  // this script — zmpl mangles JS backslash escapes.
  function kwAuthCard(scheme) {
    return {
      scheme: scheme,
      token: "",
      stored: false,
      who: "",
      expires: "",
      expired: false,
      inspecting: false,
      jwt_header: "",
      jwt_claims: "",
      init() {
        this.refresh();
      },
      key() {
        return "kw:auth:token:" + this.scheme;
      },
      decodePart(part) {
        var s = part.replace(/-/g, "+").replace(/_/g, "/");
        while (s.length % 4) s += "=";
        var bytes = Uint8Array.from(atob(s), function (c) { return c.charCodeAt(0); });
        return JSON.parse(new TextDecoder().decode(bytes));
      },
      refresh() {
        var t = sessionStorage.getItem(this.key());
        this.stored = !!t;
        this.who = "";
        this.expires = "";
        this.expired = false;
        this.jwt_header = "";
        this.jwt_claims = "";
        if (!t) {
          this.inspecting = false;
          return;
        }
        try {
          var parts = t.split(".");
          var header = this.decodePart(parts[0]);
          var claims = this.decodePart(parts[1]);
          this.jwt_header = JSON.stringify(header, null, 2);
          this.jwt_claims = JSON.stringify(claims, null, 2);
          this.who = claims.preferred_username || claims.email || claims.sub || "";
          if (claims.exp) {
            var d = new Date(claims.exp * 1000);
            this.expired = d.getTime() < Date.now();
            this.expires = d.toLocaleString();
          }
        } catch (e) {
          this.jwt_header = "";
          this.jwt_claims = "not a decodable JWT";
        }
      },
      save() {
        var t = this.token.trim();
        if (!t) return;
        // Tolerate a pasted "Bearer <token>".
        if (t.toLowerCase().indexOf("bearer ") === 0) t = t.slice(7).trim();
        sessionStorage.setItem(this.key(), t);
        this.token = "";
        this.refresh();
      },
      clear() {
        sessionStorage.removeItem(this.key());
        this.refresh();
      },
    };
  }
</script>
@zig {
  if (zmpl.ref("schemes")) |schemes| {
    if (schemes.count() == 0) {
      <div class="mx-auto w-full max-w-xl rounded-xl border border-zinc-800 bg-zinc-900 px-6 py-5 text-center">
        <p class="text-sm text-zinc-300">No auth schemes are configured.</p>
        <p class="mt-1 text-xs text-zinc-500">Register an auth package's DI extension (e.g. kw-auth-oidc) to see its schemes here.</p>
      </div>
    }
    for (schemes.items(.array)) |s| {
      const name = s.getT(.string, "name") orelse "";
      const wk = s.getT(.string, "well_known") orelse "";
      const has_login = s.getT(.boolean, "has_login") orelse false;
      <section class="mx-auto w-full max-w-xl rounded-xl border bg-zinc-900 p-5 transition-colors" x-data="kwAuthCard('{{name}}')"
        :class="stored ? 'border-emerald-500/50 ring-1 ring-inset ring-emerald-500/30' : 'border-zinc-800'">
        <div class="flex items-center gap-2">
          <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="h-4 w-4 text-zinc-400">
            <path stroke-linecap="round" stroke-linejoin="round" d="M16.5 10.5V6.75a4.5 4.5 0 1 0-9 0v3.75m-.75 11.25h10.5a2.25 2.25 0 0 0 2.25-2.25v-6.75a2.25 2.25 0 0 0-2.25-2.25H6.75a2.25 2.25 0 0 0-2.25 2.25v6.75a2.25 2.25 0 0 0 2.25 2.25Z" />
          </svg>
          <h2 class="font-mono text-sm font-semibold text-zinc-100">{{name}}</h2>
          <span class="rounded bg-zinc-700/60 px-2 py-0.5 text-xs font-medium text-zinc-400" style="display:none" x-show="!stored">no token</span>
          <button style="display:none" x-show="stored" @click="clear()"
            class="ml-auto rounded-lg border border-zinc-700 px-2.5 py-1 text-xs font-medium text-zinc-300 transition-colors hover:bg-zinc-800 hover:text-zinc-100">Sign out</button>
        </div>
        <p class="mt-1.5 break-all font-mono text-xs text-zinc-500">{{wk}}</p>
        <div style="display:none" x-show="stored"
          class="mt-3 flex items-center gap-2.5 rounded-lg border border-emerald-500/40 bg-emerald-950/40 px-3 py-2.5 text-sm text-emerald-200">
          <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="2" stroke="currentColor" class="h-5 w-5 shrink-0 text-emerald-400">
            <path stroke-linecap="round" stroke-linejoin="round" d="M9 12.75 11.25 15 15 9.75M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z" />
          </svg>
          <span class="font-medium">Signed in<template x-if="who"><span> as <strong class="font-semibold" x-text="who"></strong></span></template></span>
          <span class="ml-auto text-xs" style="display:none" x-show="expires" :class="expired ? 'font-semibold text-rose-300' : 'text-emerald-300/80'"
            x-text="(expired ? 'expired ' : 'expires ') + expires"></span>
        </div>
        <div class="mt-4 flex flex-col gap-2">
    if (has_login) {
          <a href="/_introspect/auth/{{name}}/login" style="display:none" x-show="!stored"
            class="flex items-center justify-center gap-2 rounded-lg bg-sky-600 px-4 py-2 text-sm font-semibold text-white transition-colors hover:bg-sky-500">Log in with provider</a>
          <a href="/_introspect/auth/{{name}}/login" style="display:none" x-show="stored"
            class="flex items-center justify-center gap-2 rounded-lg border border-zinc-700 px-4 py-2 text-sm font-medium text-zinc-300 transition-colors hover:bg-zinc-800 hover:text-zinc-100">Log in again</a>
          <span class="text-center text-xs text-zinc-500" style="display:none" x-show="!stored">or paste a token manually</span>
    }
          <div class="flex gap-2" style="display:none" x-show="!stored">
            <input x-model="token" @keydown.enter.prevent="save()" placeholder="Bearer token" spellcheck="false"
              class="min-w-0 flex-1 rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-2 font-mono text-xs text-zinc-100 placeholder:text-zinc-600 focus:border-sky-500 focus:outline-none" />
            <button @click="save()"
              class="rounded-lg border border-zinc-700 px-3 py-2 text-sm font-medium text-zinc-300 transition-colors hover:bg-zinc-800 hover:text-zinc-100">Save</button>
          </div>
          <button style="display:none" x-show="stored" @click="inspecting = !inspecting"
            class="flex items-center justify-center gap-1.5 rounded-lg border border-zinc-700 px-3 py-1.5 text-xs font-medium text-zinc-300 transition-colors hover:bg-zinc-800 hover:text-zinc-100">
            <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="h-3.5 w-3.5 transition-transform" :class="inspecting ? 'rotate-90' : ''">
              <path stroke-linecap="round" stroke-linejoin="round" d="m8.25 4.5 7.5 7.5-7.5 7.5" />
            </svg>
            <span x-text="inspecting ? 'Hide token' : 'Inspect token'"></span>
          </button>
          <div style="display:none" x-show="stored && inspecting" class="flex flex-col gap-2">
            <span class="text-xs font-semibold uppercase tracking-wider text-zinc-400" style="display:none" x-show="jwt_header">Header</span>
            <pre style="display:none" x-show="jwt_header" class="overflow-x-auto rounded-lg border border-zinc-800 bg-zinc-950 p-3 font-mono text-xs text-zinc-300" x-text="jwt_header"></pre>
            <span class="text-xs font-semibold uppercase tracking-wider text-zinc-400">Claims</span>
            <pre class="overflow-x-auto rounded-lg border border-zinc-800 bg-zinc-950 p-3 font-mono text-xs text-zinc-300" x-text="jwt_claims"></pre>
          </div>
        </div>
      </section>
    }
  }
}
