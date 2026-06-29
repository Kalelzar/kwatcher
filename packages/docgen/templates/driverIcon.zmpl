@if ($.tag == "ok")
<span class="flex min-w-0 flex-row items-center gap-2.5">
  <img class="h-7 w-7 shrink-0 rounded object-contain aspect-square" src="/_introspect/{{$.kind}}/{{$.key}}/{{$.fingerprint}}/favicon.svg" alt="The '{{$.kind}}' driver {{$.key}}" />
  <span class="truncate">{{$.key}}</span>
</span>
@else
<span class="text-red-400">Error: Invalid Driver</span>
@end
