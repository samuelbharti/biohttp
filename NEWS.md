# biohttp 0.1.0

First version with a public contract. The envelope shape is fixed from here;
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

## Batched calls

* `perform_many()` performs a list of prepared requests and returns a list of
  envelopes the same length and **in the same order**, so a caller zips results
  back onto its inputs by position.
* `get_json_many()` and `post_json_many()` serve whatever the cache already
  holds, perform only the entries it is missing, and store the successes. A warm
  gene list becomes zero requests, and a half-warm one becomes only as many as
  are genuinely unknown.
* Keys are built exactly the way the single-call wrappers build theirs, so a
  batch reuses entries a single call warmed and the other way around.
* Identical queries within one batch are collapsed to a single request, and the
  result is handed back to every position that asked for it.
* A failed entry in a batch is still never cached.
* These are for many questions to **one** source. httr2 applies `req_throttle()`
  and `req_retry()` across a whole list rather than per request, so requests are
  grouped by host and the groups run one after another. Fanning out across a
  dozen different services needs process-level concurrency, which belongs in an
  application rather than in a transport package.
* A host with an open breaker is never dispatched to, and every one of its
  requests in the batch comes back `skipped`. Inside a batch the breaker cannot
  short-circuit requests already in flight, so transport failures recorded there
  take effect on the next call.

## Query-string credentials

* The wrappers take `secret_query`, a named list of query parameters carrying a
  credential. NCBI E-utilities is why it exists: its `api_key` raises a caller
  from 3 to 10 requests a second and there is no header form, so the credential
  has to travel in the URL.
* The credential is attached at dispatch rather than by the caller, so the
  request object never holds it and nothing built from `req$url` beforehand, the
  cache key included, can carry it.
* It is deliberately **not** part of the cache key. A rate-limit credential does
  not change the answer, so letting it partition the cache would discard every
  warmed entry the moment a key was configured or rotated. A credential that
  changes *what comes back* must go in `headers`, which is part of the key.
  `SECURITY.md` states the rule.
* `redact_secrets()` is applied to the messages built from a transport or a
  parse failure, because a curl error normally carries the URL that failed. It
  matches both the raw value and the percent-encoded form a URL carries, so a
  key holding `+`, `/`, or `=` is caught.
* `httr2::req_url_query()` has no `.redact`, and passing one does not error: it
  is taken as another query parameter and appended to the URL. This package
  therefore does the redaction itself rather than delegating it.

## Migration

* `as_legacy_envelope()` translates to the older four-field shape so an existing
  app can migrate in a reviewable diff. Deprecated on arrival, scheduled for
  removal in 0.3.0.
