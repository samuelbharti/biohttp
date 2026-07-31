# biohttp 0.2.0

Batching. Additive only: nothing in the 0.1.0 contract changed, and the envelope
is untouched.

## Batched calls

* `perform_many()` performs a list of prepared requests and returns a list of
  envelopes the same length and **in the same order**, so a caller zips results
  back onto its inputs by position.
* `get_json_many()` and `post_json_many()` are the batched counterparts to
  `get_json()` and `post_json()`. They serve whatever the cache already holds,
  perform only the entries it is missing, and store the successes. A warm gene
  list becomes zero requests; a half-warm one becomes only as many as are
  genuinely unknown.
* Cache keys are built exactly the way the single-call wrappers build theirs, so
  a batch reuses entries a single call warmed and the other way around.
* A failed entry in a batch is still never cached. Same rule as `cached()`.

## Scope, and why it is what it is

`perform_many()` is for many questions to **one source**, not for querying a
dozen different services at once. httr2 documents `req_perform_parallel()` as
applying `req_throttle()` and `req_retry()` across the whole list rather than per
request, which makes it "most suitable for performing many parallel requests to
the same host, rather than a mix of different hosts".

Requests are grouped by host so that stays true even when a caller passes a mixed
list, and each host's throttle bucket stays honest. Host groups run one after
another. Fanning out across different services needs process-level concurrency
with a daemon pool, which belongs in an application rather than in a transport
package.

## Breaker

* A host with an open breaker is never dispatched to, and every one of its
  requests in the batch comes back `skipped`.
* Inside a batch the breaker cannot short-circuit requests already in flight.
  Transport failures are recorded, so they take effect on the next call. This is
  documented in `?perform_many`.

## Internal

* The post-dispatch half of `perform_with()` is now `classify_result()`, shared
  by the single and the batched paths, so the three failure classes have exactly
  one implementation. A test asserts they share it.

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
