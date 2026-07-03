@if ($.tag == "ok")
@partial cronNextFire(key: $.key, name: $.job.name, at: $.job.next_fire_at, in: $.job.next_fire_in, delay: $.job.poll_delay)
@else

<div class="text-xs text-rose-300">Job not found.</div>
@end
