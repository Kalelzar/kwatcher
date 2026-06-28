@args title: []const u8
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>{{title}}</title>
    <script src="https://unpkg.com/htmx.org@2.0.4" integrity="sha384-HGfztofotfshcF7+8n44JQL2oJmowVChPTg48S+jvZoztPfvwD79OC/LTtG6dMp+" crossorigin="anonymous"></script>
    <script src="https://unpkg.com/idiomorph@0.7.4/dist/idiomorph-ext.min.js" integrity="sha384-SsScJKzATF/w6suEEdLbgYGsYFLzeKfOA6PY+/C5ZPxOSuA+ARquqtz/BZz9JWU8" crossorigin="anonymous"></script>
    <script src="https://unpkg.com/@tailwindcss/browser@4"></script>
    <!-- <script defer src="https://unpkg.com/htmx-ext-form-json"></script> -->
    <script defer src="https://cdn.jsdelivr.net/npm/alpinejs@3.x.x/dist/cdn.min.js"></script>
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
    </script>
  </head>
  <body class="flex h-screen overflow-hidden bg-zinc-950 text-zinc-100 antialiased" htmx-ext="morph">
    {{slots}}
  </body>
</html>
