<script>
  // The UI's own login card. The token gates the introspection UI itself and
  // lives under kw:introspect:token — distinct from the Auth tab's
  // kw:auth:token:<scheme> keys, which authenticate Try-it requests against
  // the inspected application. Slot-free fragment, so a real script is safe.
  // NOTE: no backslashes — zmpl mangles JS backslash escapes.
  function kwUiLogin() {
    return {
      token: "",
      stored: false,
      init() {
        this.stored = !!sessionStorage.getItem("kw:introspect:token");
      },
      save() {
        var t = this.token.trim();
        if (!t) return;
        // Tolerate a pasted "Bearer <token>".
        if (t.toLowerCase().indexOf("bearer ") === 0) t = t.slice(7).trim();
        sessionStorage.setItem("kw:introspect:token", t);
        location.replace("/_introspect");
      },
      signout() {
        sessionStorage.removeItem("kw:introspect:token");
        this.stored = false;
      },
    };
  }
</script>
@if ($.configured)
<div class="w-full max-w-md rounded-xl border border-zinc-800 bg-zinc-900 p-6" x-data="kwUiLogin()">
  <div class="flex items-center gap-2">
    <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="h-5 w-5 text-zinc-400">
      <path stroke-linecap="round" stroke-linejoin="round" d="M16.5 10.5V6.75a4.5 4.5 0 1 0-9 0v3.75m-.75 11.25h10.5a2.25 2.25 0 0 0 2.25-2.25v-6.75a2.25 2.25 0 0 0-2.25-2.25H6.75a2.25 2.25 0 0 0-2.25 2.25v6.75a2.25 2.25 0 0 0 2.25 2.25Z" />
    </svg>
    <h1 class="text-lg font-semibold text-zinc-100">Authentication required</h1>
  </div>
  <p class="mt-1.5 text-sm text-zinc-400">Sign in to use KW-IntrospectUI. Scheme: <code class="font-mono text-zinc-300">{{$.scheme}}</code></p>
  <div style="display:none" x-show="stored" class="mt-3 flex items-center gap-2 rounded-lg border border-amber-500/40 bg-amber-950/30 px-3 py-2 text-xs text-amber-200">
    <span>A token is already stored — it may be expired.</span>
    <a href="/_introspect" class="ml-auto font-medium text-sky-300 hover:underline">Continue</a>
    <button @click="signout()" class="font-medium text-amber-300 hover:underline">Discard</button>
  </div>
  <div class="mt-5 flex flex-col gap-2">
    @if ($.has_login)
    <a href="/_introspect/login/start"
      class="flex items-center justify-center gap-2 rounded-lg bg-sky-600 px-4 py-2 text-sm font-semibold text-white transition-colors hover:bg-sky-500">Log in with provider</a>
    <span class="text-center text-xs text-zinc-500">or paste a token manually</span>
    @end
    <div class="flex gap-2">
      <input x-model="token" @keydown.enter.prevent="save()" placeholder="Bearer token" spellcheck="false"
        class="min-w-0 flex-1 rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-2 font-mono text-xs text-zinc-100 placeholder:text-zinc-600 focus:border-sky-500 focus:outline-none" />
      <button @click="save()"
        class="rounded-lg border border-zinc-700 px-3 py-2 text-sm font-medium text-zinc-300 transition-colors hover:bg-zinc-800 hover:text-zinc-100">Save</button>
    </div>
  </div>
</div>
@else

<div class="w-full max-w-md rounded-xl border border-red-500/40 bg-red-950/40 px-6 py-5 text-center">
  <p class="text-lg font-semibold text-red-200">UI auth is not configured</p>
  <p class="mt-1 text-sm text-red-300/80">No auth scheme matches the one this mount was locked with — check the app's auth extension registration.</p>
</div>
@end
