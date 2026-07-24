@if ($.err == "")
@partial head(title: "KW-IntrospectUI — Auth") {
  <content class="flex flex-1 flex-col items-center justify-center gap-3 p-8">
    <div id="kw-auth-result" data-scheme="{{$.scheme}}" data-token="{{$.token}}" hidden></div>
    <script>
      // Hand the freshly exchanged access token to the browser and bounce
      // back to the Auth tab. The token is read from data attributes rather
      // than interpolated into script source. Deliberately flat, brace-free
      // JS: zmpl's slot parser treats `{`/`}` as group delimiters, and a
      // closer with a same-line trailer (`})();`) leaks the trailer out of
      // the slot, corrupting the script.
      var kwAuthResult = document.getElementById("kw-auth-result");
      sessionStorage.setItem("kw:auth:token:" + kwAuthResult.dataset.scheme, kwAuthResult.dataset.token);
      location.replace("/_introspect/auth");
    </script>
    <div class="h-8 w-8 animate-spin rounded-full border-2 border-zinc-600 border-t-sky-400" role="status" aria-label="Loading"></div>
    <p class="text-sm text-zinc-400">Signed in — returning to the Auth tab…</p>
  </content>
}
@else

@partial head(title: "KW-IntrospectUI — Auth") {
  <content class="flex flex-1 flex-col items-center justify-center p-8">
    <div class="w-full max-w-md rounded-xl border border-red-500/40 bg-red-950/40 px-6 py-5 text-center">
      <p class="text-lg font-semibold text-red-200">Login failed</p>
      <p class="mt-1 text-sm text-red-300/80">{{$.err}}</p>
      <a href="/_introspect/auth" class="mt-3 inline-block text-sm text-sky-300 hover:underline">Back to Auth</a>
    </div>
  </content>
}
@end
