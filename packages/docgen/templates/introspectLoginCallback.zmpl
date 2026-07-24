@if ($.err == "")
@partial head(title: "KW-IntrospectUI — Login") {
  <content class="flex flex-1 flex-col items-center justify-center gap-3 p-8">
    <div id="kw-ui-login-result" data-token="{{$.token}}" hidden></div>
    <script>
      // Hand the freshly exchanged UI access token to the browser and enter
      // the UI. Deliberately flat, brace-free JS: this script lives in a
      // partial slot, and zmpl's slot parser corrupts multi-line braced JS.
      var kwUiLoginResult = document.getElementById("kw-ui-login-result");
      sessionStorage.setItem("kw:introspect:token", kwUiLoginResult.dataset.token);
      location.replace("/_introspect");
    </script>
    <div class="h-8 w-8 animate-spin rounded-full border-2 border-zinc-600 border-t-sky-400" role="status" aria-label="Loading"></div>
    <p class="text-sm text-zinc-400">Signed in — entering KW-IntrospectUI…</p>
  </content>
}
@else

@partial head(title: "KW-IntrospectUI — Login") {
  <content class="flex flex-1 flex-col items-center justify-center p-8">
    <div class="w-full max-w-md rounded-xl border border-red-500/40 bg-red-950/40 px-6 py-5 text-center">
      <p class="text-lg font-semibold text-red-200">Login failed</p>
      <p class="mt-1 text-sm text-red-300/80">{{$.err}}</p>
      <a href="/_introspect/login" class="mt-3 inline-block text-sm text-sky-300 hover:underline">Back to login</a>
    </div>
  </content>
}
@end
