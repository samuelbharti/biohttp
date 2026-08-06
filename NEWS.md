# biohttp 0.1.2

Preparation for a first CRAN submission. Everything here came out of reading the
package the way a CRAN reviewer reads one, which is a different pass from the
one that gets a suite green.

## Changed

* The disk cache defaults to `tools::R_user_dir("biohttp", "cache")` rather than
  `data/cache`. The old default was a relative path, so it resolved against
  whatever directory R was started in: a job run from two working directories
  quietly kept two caches, and neither knew about the other. CRAN policy also
  asks that a package write outside `tempdir()` only where a user expects it to,
  and a directory appearing under the working directory is not that place. Only
  a caller who had opted into the disk tier with `BIOHTTP_CACHE_DISK` is
  affected, and setting `BIOHTTP_CACHE_DIR` still overrides it. An existing
  `data/cache` is not migrated; it is a cache, so the cost of abandoning it is
  one cold start.
* `tools` joins `Imports` for that call. It ships with R, so it adds nothing to
  what a consumer installs, and it is declared because `R CMD check` requires a
  declaration for anything reached with `::`.
* `DESCRIPTION` gains a reference for the circuit breaker, names the language as
  `en-US`, and hyphenates "service-specific".

## Fixed

* Every environment variable the package reads now treats an empty export the
  same way it treats an absent one. `Sys.getenv()`'s default argument only fires
  when a name is absent, so a container passing through a variable its operator
  never filled in got `""` rather than the default, and four readers were doing
  that. `env_num()` and `env_flag()` had always had the rule; `env_chr()` gives
  it to the rest.

  The one that mattered was `BIOHTTP_CALLER_IDENTITY`. Exported empty, it sent
  `User-Agent: biohttp/0.1.2` out as `/0.1.2`: a version with nothing in front
  of it, which is the one thing a user agent exists to carry, on a package whose
  point is being attributable to the service you are calling. Every test in the
  suite ran that way, because `setup.R` clears those variables by exporting them
  empty, and no test looked.

  `BIOHTTP_CACHE_DIR` was the same defect with a smaller blast radius: `""` as a
  directory is the working directory, which is what the change above removes.
  `BIOHTTP_CONTACT_URL`, `BIOHTTP_CONTACT_EMAIL` and `BIOHTTP_CACHE_SALT` all
  default to `""` anyway, so they read the same as before.
* The `status_message()` example no longer calls `withr`, which is in
  `Suggests`. An example may only use what `Imports` guarantees: CRAN checks
  with `_R_CHECK_DEPENDS_ONLY_` set, where a `Suggests` package is simply absent
  and the example errors. It now sets the option with `options()` and restores
  it, which also satisfies the separate rule that an example puts back anything
  it changes.

## Added

* `inst/CITATION` is shipped, so `citation("biohttp")` carries the Zenodo DOI
  from an installed copy. `CITATION.cff` is in `.Rbuildignore` and never reached
  a tarball, so the README had been promising something only a source checkout
  could deliver. Both exist now, because GitHub's cite box reads the `.cff` and
  R reads `inst/CITATION`.
* `cran-comments.md`, which `.Rbuildignore` had been reserving a line for since
  the package was scaffolded, without the file ever existing.

## Documentation

* The README linked to `CONTRIBUTING.md` and `LICENSE.md` by relative path. Both
  are in `.Rbuildignore`, so neither reaches a tarball and both links were dead
  for anyone reading the README somewhere other than GitHub, which from here
  includes the CRAN package page. They are absolute now.
* The README's `Imports` list named five packages where `DESCRIPTION` names six.
  A README that contradicts the `DESCRIPTION` printed beside it on the CRAN page
  is worth more than the line it saves.
* The status line no longer carries a version number. The last one went stale
  within a release of being written, and `NEWS.md` already answers the question.

# biohttp 0.1.1

Everything here came out of the first real migration onto 0.1.0, which is where
a transport contract meets an app that already had its own opinions.

## Fixed

* `cache_reset()` no longer orphans a reference taken from `cache()`. It used to
  drop the store, so the next `cache()` built a new one and anything held
  earlier pointed at a dead object: writes went where nothing else could see
  them, reads returned stale entries, and the only symptom was a hit rate
  quietly falling to zero. The reset now clears the store in place when no cache
  setting has changed, and only rebuilds when one has, which is what test
  isolation needs (#21).

## Added

* `BIOHTTP_CACHE_MAX_N` bounds the memory tier by number of entries.
  `BIOHTTP_CACHE_MAX_SIZE` bounds bytes, and a long-running process answering
  many small responses stays well under that while holding far more entries than
  intended. Defaults to `cachem`'s own `Inf`, so nothing changes unless it is
  set (#22).
* `status_message()` produces every user-facing sentence in the package, and
  setting the `biohttp.status_message` option replaces them. That is how an app
  keeps its own voice, or localizes, while adopting the transport. Returning
  anything other than a single non-empty string falls back to the built-in, so
  overriding one status and leaving the rest is the expected use. The override
  runs inside `tryCatch()`, because it sits on the failure path and the package
  promises never to raise there (#23).

## Changed

* The `status_*()` constructors used to hardcode their own copies of sentences
  that also lived in `http_error_message()`, and the two had drifted: three
  different sentences existed for "temporarily unavailable". They now share one
  set. `status_error()`'s default gains "Please try again." as a result, which is
  the only user-visible wording change.
* A 408 now reads "took too long to respond" rather than the generic "could not
  retrieve". `classify_http()` has always called 408 a timeout, so the envelope
  said `timeout` while the sentence a user read said something else. They agree
  now.
* The vignette's cache table documents `BIOHTTP_CACHE_MAX_SIZE` and
  `BIOHTTP_CACHE_DISK_TTL`, which it had never listed.
* A test asserts `DESCRIPTION`, `.zenodo.json` and `CITATION.cff` agree on the
  version. Nothing read it from one source, so a stale archive label was a
  matter of time.

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
