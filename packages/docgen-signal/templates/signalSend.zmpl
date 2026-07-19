@if ($.status == "")

<div hx-get="/_introspect/signal/{{$.key}}/routes" hx-target="#signal-pane" hx-swap="innerHTML" hx-trigger="load"></div>
@else

<div class="p-6 text-sm text-rose-300">{{$.status}}</div>
@end
