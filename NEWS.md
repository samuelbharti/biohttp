# biohttp 0.1.0

First release with a public contract. The envelope shape is fixed from here;
changing it after this is a breaking change.

## The contract

* Every call returns an `envelope()` and never raises on an HTTP or a parse
  failure. Callers branch on `res$status` and write no `tryCatch()` of their
  own.
* Seven statuses, ordered best to worst: `ok`, `no_data`, `stale`,
  `rate_limited`, `timeout`, `skipped`, `error`. `ok` is derived from `status`
  so the two cannot disagree.
* `error` carries one sentence fit for a user; `detail` carries the technical
  cause for a log. They are never mixed.
* `vignette("biohttp")` documents the whole thing.

## Transport

* `get_json()`, `post_json()`, and `get_text()` assemble, perform, and cache a
  call. `perform()` and `perform_text()` take a request you built yourself.
* `req_defaults()` applies the timeout, bounded retry on transient codes, an
  attributable user agent, optional throttling, and redacted headers. A token
  never prints in an inspected request, a log line, or an error message.
* Per-host circuit breaking, where **only a transport failure counts against a
  host**. A 5xx, or a 2xx with an unreadable body, proves the host is reachable
  and clears the count.
* A success-only cache. A failure is never stored, so a transient outage
  resolves itself instead of getting stuck. The disk tier is opt-in and degrades
  to memory-only when its directory is not usable.

## Migration

* `as_legacy_envelope()` translates to the older four-field shape so an existing
  app can migrate in a reviewable diff. Deprecated on arrival, scheduled for
  removal in 0.3.0.
