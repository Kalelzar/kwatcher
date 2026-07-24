@args title: []const u8
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>{{title}}</title>
    <script src="/_introspect/assets/htmx.min.js"></script>
    <script src="/_introspect/assets/idiomorph-ext.min.js"></script>
    <script src="/_introspect/assets/tailwind-browser.js"></script>
    <script defer src="/_introspect/assets/alpine.min.js"></script>
    <script>
      // Track the active driver. The ok driver page renders a `#kw-current-driver`
      // marker in its content pane (the 404 page omits it). Driver switches swap only
      // `#content`, leaving the sidebar in place, so we (a) persist the selection for
      // the index redirect and (b) move the sidebar's highlight client-side. Runs on
      // initial load and after every htmx settle (content swap + sidebar load).
      (function () {
        function sync() {
          var el = document.getElementById("kw-current-driver");
          var cur = el && el.dataset.kind && el.dataset.key
            ? el.dataset.kind + "/" + el.dataset.key
            : null;
          if (cur) localStorage.setItem("kw:last-driver", cur);
          document.querySelectorAll("a[data-driver]").forEach(function (a) {
            if (a.dataset.driver === cur) a.setAttribute("aria-current", "page");
            else a.removeAttribute("aria-current");
          });
        }
        document.addEventListener("DOMContentLoaded", sync);
        document.addEventListener("htmx:afterSettle", sync);
      })();

      // UI auth plumbing. When the mount is auth-wrapped, every inner call
      // (htmx fragment/action) must carry the UI bearer token stored by
      // /_introspect/login under kw:introspect:token. A 401 from any inner
      // call bounces to the login page (guarded against looping there).
      // On an unprotected mount no token exists and this is inert.
      (function () {
        document.addEventListener("htmx:configRequest", function (evt) {
          var t = sessionStorage.getItem("kw:introspect:token");
          if (t) evt.detail.headers["Authorization"] = "Bearer " + t;
        });
        document.addEventListener("htmx:responseError", function (evt) {
          var status = evt.detail.xhr ? evt.detail.xhr.status : 0;
          var on_login = window.location.pathname.indexOf("/_introspect/login") === 0;
          if (status === 401 && !on_login) window.location.href = "/_introspect/login";
        });
      })();
    </script>
  </head>
  <body class="flex h-screen overflow-hidden bg-zinc-950 text-zinc-100 antialiased" htmx-ext="morph">
    {{slots}}
    <!-- Backend-disconnected overlay: shown when any htmx fragment request fails at the
         network level (htmx:sendError — connection refused/reset, e.g. the backend shut
         down after a signal Send). Probes the server every 3s and reloads the page only
         once a probe succeeds, so we never navigate onto the browser's error page. -->
    <div x-data="{ down: false, probe() { fetch(window.location.href, { cache: 'no-store' }).then(r => { if (r.ok) window.location.reload() }).catch(() => {}) }, engage() { if (this.down) return; this.down = true; setInterval(() => this.probe(), 3000) } }"
      x-init="document.body.addEventListener('htmx:sendError', () => engage())"
      x-show="down" style="display: none"
      class="fixed inset-0 z-50 flex items-center justify-center bg-zinc-950/80 backdrop-blur-sm">
      <div class="w-full max-w-md rounded-xl border border-rose-500/40 bg-zinc-900 px-6 py-8 text-center">
        <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="mx-auto h-10 w-10 text-rose-400">
          <path stroke-linecap="round" stroke-linejoin="round" d="M9 7V4m6 3V4M7 10.5a5 5 0 0 0 10 0V10H7v.5M12 15.5V18m0 0c0 1.5-1 2.5-2.5 2.5S7 21.5 7 22" />
        </svg>
        <p class="mt-4 text-lg font-semibold text-zinc-100">Backend has disconnected</p>
        <p class="mt-1 text-sm text-zinc-400">The introspected application is no longer reachable.</p>
        <p class="mt-1 animate-pulse text-xs text-zinc-500">Retrying automatically&hellip;</p>
        <button @click="probe()"
          class="mt-5 inline-flex items-center gap-1.5 rounded-lg border border-zinc-700 px-3 py-1.5 text-sm font-medium text-zinc-300 transition-colors hover:bg-zinc-800 hover:text-zinc-100">
          <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="h-4 w-4">
            <path stroke-linecap="round" stroke-linejoin="round" d="M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0 3.181 3.183a8.25 8.25 0 0 0 13.803-3.7M4.031 9.865a8.25 8.25 0 0 1 13.803-3.7l3.181 3.182m0-4.991v4.99" />
          </svg>
          Retry now
        </button>
      </div>
    </div>
  </body>
</html>
