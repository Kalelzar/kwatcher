<section class="flex min-w-0 flex-1 flex-col overflow-y-auto">
  <div id="signal-pane" class="flex min-w-0 flex-1 flex-col" hx-get="/_introspect/signal/{{$.key}}/routes" hx-trigger="load" hx-swap="innerHTML"></div>
</section>
