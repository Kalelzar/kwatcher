<ul class="flex flex-col gap-0.5">
  @for ($.drivers) |driver| {
    @html {
      @if (std.mem.eql(u8, try driver.object.get("key").?.coerce([]const u8), try zmpl.getCoerce([]const u8, "active.key")) and std.mem.eql(u8, try driver.object.get("kind").?.coerce([]const u8), try zmpl.getCoerce([]const u8, "active.kind")))

      <li>
        <a href="/_introspect/{{driver.kind}}/{{driver.key}}" data-driver="{{driver.kind}}/{{driver.key}}" aria-current="page"
           hx-get="/_introspect/{{driver.kind}}/{{driver.key}}" hx-target="#content" hx-select="#content" hx-swap="outerHTML" hx-push-url="true" hx-disinherit="*"
           class="flex items-center rounded-lg px-3 py-2 text-sm text-zinc-300 transition-colors hover:bg-zinc-700/50 hover:text-zinc-100 aria-[current=page]:bg-zinc-700/70 aria-[current=page]:font-medium aria-[current=page]:text-sky-300 aria-[current=page]:ring-1 aria-[current=page]:ring-inset aria-[current=page]:ring-sky-500/50">
          <div hx-get="/_introspect/{{driver.kind}}/{{driver.key}}/icon" hx-trigger="load" hx-swap="outerHTML"> {{driver.key}} </div>
        </a>
      </li>

      @else

      <li>
        <a href="/_introspect/{{driver.kind}}/{{driver.key}}" data-driver="{{driver.kind}}/{{driver.key}}"
           hx-get="/_introspect/{{driver.kind}}/{{driver.key}}" hx-target="#content" hx-select="#content" hx-swap="outerHTML" hx-push-url="true" hx-disinherit="*"
           class="flex items-center rounded-lg px-3 py-2 text-sm text-zinc-300 transition-colors hover:bg-zinc-700/50 hover:text-zinc-100 aria-[current=page]:bg-zinc-700/70 aria-[current=page]:font-medium aria-[current=page]:text-sky-300 aria-[current=page]:ring-1 aria-[current=page]:ring-inset aria-[current=page]:ring-sky-500/50">
          <div hx-get="/_introspect/{{driver.kind}}/{{driver.key}}/icon" hx-trigger="load" hx-swap="outerHTML"> {{driver.key}} </div>
        </a>
      </li>
      @end
    }
  }
</ul>
