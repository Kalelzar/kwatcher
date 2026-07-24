@if ($.tag == "ok")
<nav class="flex shrink-0 items-center border-b border-zinc-700/60 px-2">
  <button hx-get="/_introspect/http/{{$.key}}/op/{{$.operation.id}}/examples" hx-target="#op-panel" hx-swap="innerHTML"
    class="border-b-2 border-transparent px-4 py-3 text-sm font-medium text-zinc-400 transition-colors hover:text-zinc-200">Examples</button>
  <button hx-get="/_introspect/http/{{$.key}}/op/{{$.operation.id}}/try" hx-target="#op-panel" hx-swap="innerHTML"
    class="border-b-2 border-sky-400 px-4 py-3 text-sm font-medium text-zinc-100">Try it</button>
  <span class="ml-auto self-center pr-2 font-mono text-xs text-zinc-400">{{$.operation.method}} {{$.operation.path}}</span>
</nav>

<script>
  // Try-it tab state (Alpine), scoped to the template that uses it. Like SwaggerUI:
  // the request is built from the form fields and fired from the BROWSER against the
  // served http mount. `port` is that mount's configured port (this UI may be served by
  // a *different* mount, e.g. a private introspection port); when set we build an absolute
  // URL on the current host at that port, so the fetch is cross-origin and the target mount
  // must send CORS headers — no server proxy. Empty `port` falls back to same-origin. The
  // response body is then POSTed to a content-type-specific server renderer
  // (/_introspect/render/<type>) whose HTML fragment we drop into the viewer.
  function kwTryIt(method, path, port, scheme) {
    return {
      method: method,
      path: path,
      port: port,
      // Security scheme name for secured operations ("" = open). The token is
      // what the Auth tab stored under kw:auth:token:<scheme>.
      scheme: scheme,
      loading: false,
      sent: false,
      status: null,
      statusText: "",
      ms: 0,
      ctype: "",
      rendered: "",
      errors: {},
      touched: {},
      attempted: false,
      init() {
        this.validate();
      },
      token() {
        return this.scheme ? sessionStorage.getItem("kw:auth:token:" + this.scheme) : null;
      },
      hasToken() {
        return !!this.token();
      },
      // Decoded claims of the stored token (null for non-JWTs), for the
      // signed-in banner. NOTE: no backslashes here — zmpl mangles JS
      // backslash escapes.
      tokenClaims() {
        var t = this.token();
        if (!t) return null;
        try {
          var s = t.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
          while (s.length % 4) s += "=";
          var bytes = Uint8Array.from(atob(s), function (c) { return c.charCodeAt(0); });
          return JSON.parse(new TextDecoder().decode(bytes));
        } catch (e) {
          return null;
        }
      },
      tokenWho() {
        var c = this.tokenClaims();
        if (!c) return "";
        return c.preferred_username || c.email || c.sub || "";
      },
      tokenExpires() {
        var c = this.tokenClaims();
        if (!c || !c.exp) return "";
        return new Date(c.exp * 1000).toLocaleString();
      },
      tokenExpired() {
        var c = this.tokenClaims();
        return !!(c && c.exp && c.exp * 1000 < Date.now());
      },
      // Block-until-valid validation. We only flag shape problems the backend would
      // reject generically: required params empty, primitive type mismatch, and — only
      // when the body content-type is JSON — an unparseable body. Re-runs on every
      // input so Send enables/disables live.
      validate() {
        var errs = {};
        this.$root.querySelectorAll("[data-param]").forEach(function (el) {
          var key = el.dataset.loc + ":" + el.dataset.name;
          var val = el.value.trim();
          var type = el.dataset.type || "";
          if (!val) {
            if (el.dataset.req === "required") errs[key] = "required";
            return;
          }
          if (type.indexOf("integer") === 0) {
            if (!Number.isInteger(Number(val))) errs[key] = "not an integer";
          } else if (type.indexOf("number") === 0) {
            if (!Number.isFinite(Number(val))) errs[key] = "not a number";
          } else if (type === "boolean") {
            if (val !== "true" && val !== "false") errs[key] = "must be true or false";
          }
        });
        // A declared request body is required: empty is invalid. When the body
        // content-type is JSON, a non-empty body must also parse.
        var bodyEl = this.$root.querySelector("[data-body]");
        if (bodyEl) {
          var ct = bodyEl.dataset.ct || "";
          var bval = bodyEl.value.trim();
          if (!bval) {
            errs["body"] = "required";
          } else if (ct === "application/json" || ct.endsWith("+json")) {
            try {
              JSON.parse(bval);
            } catch (e) {
              errs["body"] = "invalid JSON";
            }
          }
        }
        // Secured operations block until a token exists — authenticate in the
        // Auth tab (or paste one there) first.
        if (this.scheme && !this.hasToken()) errs["auth"] = "authenticate in the Auth tab";
        this.errors = errs;
      },
      isValid() {
        return Object.keys(this.errors).length === 0;
      },
      errorCount() {
        return Object.keys(this.errors).length;
      },
      // Only surface a field's error once it's been left (blur) or a send has been
      // attempted — don't barrage the user while they're still typing.
      showError(key) {
        return this.errors[key] && (this.attempted || this.touched[key]);
      },
      // Map a response content type to its server renderer, or null to fall back to
      // escaped plain text. Keep in sync with the /_introspect/render/* routes.
      rendererFor(ct) {
        if (ct === "application/json" || ct.endsWith("+json"))
          return "/_introspect/render/application/json";
        return null;
      },
      escapeText(text) {
        return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
      },
      statusClass() {
        if (this.status === 0) return "bg-rose-500/15 text-rose-300";
        if (this.status < 300) return "bg-emerald-500/15 text-emerald-300";
        if (this.status < 400) return "bg-sky-500/15 text-sky-300";
        if (this.status < 500) return "bg-amber-500/15 text-amber-300";
        return "bg-rose-500/15 text-rose-300";
      },
      async send() {
        this.validate();
        if (!this.isValid()) {
          this.attempted = true;
          return;
        }
        this.loading = true;
        this.sent = true;
        this.rendered = "";
        // Build the URL + headers from the per-parameter inputs: path params
        // substitute into the template, query params append, header params become
        // request headers. Empty values are skipped (optional params).
        var base = this.port ? (window.location.protocol + "//" + window.location.hostname + ":" + this.port) : "";
        var url = base + this.path;
        var query = [];
        var headers = {};
        this.$root.querySelectorAll("[data-param]").forEach(function (el) {
          var val = el.value;
          if (!val) return;
          var name = el.dataset.name;
          if (el.dataset.loc === "path")
            url = url.replace("{" + name + "}", encodeURIComponent(val));
          else if (el.dataset.loc === "query")
            query.push(encodeURIComponent(name) + "=" + encodeURIComponent(val));
          else if (el.dataset.loc === "header") headers[name] = val;
        });
        if (query.length) url += (url.indexOf("?") === -1 ? "?" : "&") + query.join("&");

        if (this.scheme && this.hasToken()) headers["Authorization"] = "Bearer " + this.token();

        var opts = { method: this.method, headers: headers };
        var bodyEl = this.$root.querySelector("[data-body]");
        if (bodyEl && bodyEl.value.trim()) {
          headers["Content-Type"] = bodyEl.dataset.ct || "application/json";
          opts.body = bodyEl.value;
        }

        var t0 = performance.now();
        var res, text;
        try {
          res = await fetch(url, opts);
          text = await res.text();
        } catch (err) {
          this.ms = Math.round(performance.now() - t0);
          this.status = 0;
          this.statusText = "Network error";
          this.ctype = "";
          this.rendered = "<p class='text-sm text-rose-300'>" + this.escapeText(String(err)) + "</p>";
          this.loading = false;
          return;
        }
        this.ms = Math.round(performance.now() - t0);
        this.status = res.status;
        this.statusText = res.statusText;
        this.ctype = (res.headers.get("content-type") || "").split(";")[0].trim();

        // Render the body server-side, keyed on content type. Fall back to escaped
        // text for types without a renderer (or if the renderer call fails).
        try {
          var endpoint = this.rendererFor(this.ctype);
          if (endpoint) {
            var r = await fetch(endpoint, {
              method: "POST",
              headers: { "Content-Type": "text/plain" },
              body: text,
            });
            this.rendered = await r.text();
          } else {
            this.rendered =
              "<pre class='overflow-x-auto rounded-lg border border-zinc-800 bg-zinc-900 p-3 font-mono text-xs text-zinc-300'><code>" +
              this.escapeText(text) +
              "</code></pre>";
          }
        } catch (err) {
          this.rendered =
            "<pre class='overflow-x-auto rounded-lg border border-zinc-800 bg-zinc-900 p-3 font-mono text-xs text-zinc-300'><code>" +
            this.escapeText(text) +
            "</code></pre>";
        }
        this.loading = false;
      },
    };
  }
</script>

@if ($.operation.security)
<div class="min-h-0 flex-1 overflow-y-auto p-4" x-data="kwTryIt('{{$.operation.method}}', '{{$.operation.path}}', '{{$.port}}', '{{$.operation.security.scheme}}')">
@else

<div class="min-h-0 flex-1 overflow-y-auto p-4" x-data="kwTryIt('{{$.operation.method}}', '{{$.operation.path}}', '{{$.port}}', '')">
@end
  <form @submit.prevent="send()" @input="validate()" class="flex flex-col gap-4">
    <div class="flex items-center gap-2">
      @partial methodBadge(method: $.operation.method)
      <code class="font-mono text-sm text-zinc-200">{{$.operation.path}}</code>
    </div>

    @if ($.operation.security)
    <div style="display:none" x-show="!hasToken()" class="flex items-center gap-2 rounded-lg border border-amber-500/40 bg-amber-950/30 px-3 py-2 text-xs text-amber-200">
      <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="h-4 w-4 shrink-0">
        <path stroke-linecap="round" stroke-linejoin="round" d="M16.5 10.5V6.75a4.5 4.5 0 1 0-9 0v3.75m-.75 11.25h10.5a2.25 2.25 0 0 0 2.25-2.25v-6.75a2.25 2.25 0 0 0-2.25-2.25H6.75a2.25 2.25 0 0 0-2.25 2.25v6.75a2.25 2.25 0 0 0 2.25 2.25Z" />
      </svg>
      <span>Requires <code class="font-mono">{{$.operation.security.scheme}}</code> authentication.</span>
      <a href="/_introspect/auth" class="ml-auto font-medium text-sky-300 hover:underline">Authenticate</a>
    </div>
    <a href="/_introspect/auth" style="display:none" x-show="hasToken()" title="Open the Auth tab ({{$.operation.security.scheme}})"
      class="flex items-center gap-2.5 rounded-lg border border-emerald-500/40 bg-emerald-950/40 px-3 py-2.5 text-sm text-emerald-200 transition-colors hover:border-emerald-400/60 hover:bg-emerald-950/70">
      <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="2" stroke="currentColor" class="h-5 w-5 shrink-0 text-emerald-400">
        <path stroke-linecap="round" stroke-linejoin="round" d="M9 12.75 11.25 15 15 9.75M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z" />
      </svg>
      <span class="font-medium">Signed in<template x-if="tokenWho()"><span> as <strong class="font-semibold" x-text="tokenWho()"></strong></span></template></span>
      <span class="ml-auto text-xs" style="display:none" x-show="tokenExpires()" :class="tokenExpired() ? 'font-semibold text-rose-300' : 'text-emerald-300/80'"
        x-text="(tokenExpired() ? 'expired ' : 'expires ') + tokenExpires()"></span>
    </a>
    @end

    @zig {
      if (zmpl.ref("operation.parameters")) |params| {
        if (params.count() > 0) {
          <fieldset class="flex flex-col gap-2">
            <legend class="mb-1 text-xs font-semibold uppercase tracking-wider text-zinc-400">Parameters</legend>
        for (params.items(.array)) |p| {
          const name = p.getT(.string, "name") orelse "";
          const location = p.getT(.string, "location") orelse "";
          const ptype = p.getT(.string, "type") orelse "";
          const reqLabel: []const u8 = if (p.getT(.boolean, "required") orelse false) "required" else "optional";
          const example = p.getT(.string, "example") orelse "";
          <label class="flex flex-col gap-1 text-sm">
            <span class="text-zinc-300"><code class="font-mono text-zinc-200">{{name}}</code> <span class="text-xs text-zinc-400">{{location}} · {{ptype}} · {{reqLabel}}</span></span>
            <input data-param data-loc="{{location}}" data-name="{{name}}" data-type="{{ptype}}" data-req="{{reqLabel}}" value="{{example}}" placeholder="{{ptype}}" spellcheck="false"
              @blur="touched['{{location}}:{{name}}'] = true"
              class="rounded-lg border bg-zinc-900 px-3 py-2 font-mono text-sm text-zinc-100 placeholder:text-zinc-600 focus:outline-none"
              :class="showError('{{location}}:{{name}}') ? 'border-rose-500 focus:border-rose-500' : 'border-zinc-700 focus:border-sky-500'" />
            <span style="display:none" x-show="showError('{{location}}:{{name}}')" x-text="errors['{{location}}:{{name}}']" class="text-xs text-rose-400"></span>
          </label>
        }
          </fieldset>
        }
      }
    }

    @if ($.operation.body)
    <fieldset class="flex flex-col gap-1">
      <legend class="mb-1 text-xs font-semibold uppercase tracking-wider text-zinc-400">Body <span class="font-mono normal-case text-zinc-400">{{$.operation.body.content_type}}</span></legend>
      <textarea data-body data-ct="{{$.operation.body.content_type}}" rows="8" spellcheck="false" placeholder="JSON request body"
        @blur="touched['body'] = true"
        class="rounded-lg border bg-zinc-900 px-3 py-2 font-mono text-xs text-zinc-100 placeholder:text-zinc-600 focus:outline-none"
        :class="showError('body') ? 'border-rose-500 focus:border-rose-500' : 'border-zinc-700 focus:border-sky-500'">{{$.operation.request_example.body}}</textarea>
      <span style="display:none" x-show="showError('body')" x-text="errors['body']" class="text-xs text-rose-400"></span>
    </fieldset>
    @end

    <button type="submit" :disabled="loading"
      class="flex items-center justify-center gap-2 rounded-lg bg-sky-600 px-4 py-2 text-sm font-semibold text-white transition-colors hover:bg-sky-500 disabled:cursor-not-allowed disabled:opacity-50">
      <span style="display:none" x-show="loading" class="h-4 w-4 animate-spin rounded-full border-2 border-white/40 border-t-white"></span>
      <span x-text="loading ? 'Sending…' : 'Send request'"></span>
    </button>
    <p style="display:none" x-show="attempted && !isValid()" class="text-center text-xs text-rose-400" x-text="'Fix ' + errorCount() + (errorCount() === 1 ? ' error' : ' errors') + ' to send'"></p>

    <div style="display:none" x-show="sent" class="flex flex-col gap-1.5">
      <div class="flex items-center gap-2 text-xs font-semibold uppercase tracking-wider text-zinc-400">
        Response
        <span class="rounded px-2 py-0.5 font-mono normal-case" :class="statusClass()" x-text="status === 0 ? 'ERR' : status"></span>
        <span class="font-mono normal-case text-zinc-400" x-text="statusText"></span>
        <span class="ml-auto font-mono normal-case text-zinc-500" x-text="ms + ' ms' + (ctype ? ' · ' + ctype : '')"></span>
      </div>
      <div x-html="rendered"></div>
    </div>
  </form>
</div>
@else

<div class="flex flex-1 items-center justify-center p-8 text-center text-sm text-rose-300">Operation not found.</div>
@end
