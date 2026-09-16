# biohttp <img src="man/figures/logo.png" align="right" height="139" alt="" />

<!-- badges: start -->
[![Lifecycle: stable](https://img.shields.io/badge/lifecycle-stable-brightgreen.svg)](https://lifecycle.r-lib.org/articles/stages.html#stable)
[![CRAN status](https://www.r-pkg.org/badges/version/biohttp)](https://CRAN.R-project.org/package=biohttp)
[![R-CMD-check](https://github.com/samuelbharti/biohttp/actions/workflows/r.yml/badge.svg)](https://github.com/samuelbharti/biohttp/actions/workflows/r.yml)
[![r-universe](https://samuelbharti.r-universe.dev/badges/biohttp)](https://samuelbharti.r-universe.dev/biohttp)
[![DOI](https://img.shields.io/badge/DOI-10.5281%2Fzenodo.21731864-1682D4)](https://doi.org/10.5281/zenodo.21731864)
<!-- badges: end -->

One HTTP transport layer for R clients of biological web services.

Documentation is at <https://www.samuelbharti.com/biohttp/>.

## Installation

```r
install.packages("biohttp")
```

Or from r-universe, which often has a newer build than CRAN and ships prebuilt
binaries:

```r
install.packages("biohttp", repos = "https://samuelbharti.r-universe.dev")
```

Or straight from GitHub, if you want a specific commit or a branch that has not
been released yet:

```r
# pak resolves dependencies properly and is the one to reach for
pak::pak("samuelbharti/biohttp")

# a tagged release rather than the tip of main. The tags are listed at
# https://github.com/samuelbharti/biohttp/releases
pak::pak("samuelbharti/biohttp@v0.1.2")
```

GitHub installs are built from source, so they need the usual R build tools.
Use CRAN unless you need something that has not been released yet.

## Why

An app that talks to a biological web service usually grows its own HTTP layer,
and the next app starts by copying it. The copies then drift. One returns a
value where another raises a condition. A bug gets fixed in one and not the
rest. Every copy has its own opinion about whether a 500 means the source is
down.

The awkward part is that none of that is really about biology. It is retry,
timeouts, caching, and deciding what a failure means, written again each time
because it was easier to copy than to extract.

biohttp is that layer written once and installed rather than copied. It knows
how to make an HTTP call and report what happened. It does not know what a gene
is, and it never will.

## What it does

- **A call returns a value, never a condition.** Transport failure, a non-success
  status code, and a 2xx with an unreadable body are three distinct outcomes the
  caller branches on.
- **Per-host circuit breaking.** Only a transport failure trips the breaker. Once
  a response is in hand the host is reachable, so a 5xx or a garbage body must
  never be mistaken for the host being down.
- **Sensible request defaults.** Timeout, retry with a transient-failure
  predicate, an attributable user agent, optional throttling, and headers passed
  through `httr2::req_headers(.redact = )` so a token never prints in a logged
  request or an error.
- **A success-only cache.** A failed call is never stored. Memory tier by
  default, opt-in disk tier that degrades to memory-only when the directory is
  not writable.
- **Batched calls.** `get_json_many()`, `post_json_many()`, and
  `get_text_many()` ask many questions of one source at once, in order, and
  only the entries the cache is missing reach the network.
- **Query-string credentials.** For a service like NCBI E-utilities that has no
  header form, `secret_query` attaches the key at dispatch, keeps it out of the
  cache key, and redacts it from error messages.

## What it does not do

- No Shiny. Not in Imports, not in Suggests, not in tests.
- No service-specific knowledge. Nothing here knows what a gene is. That belongs
  in a client package built on top.
- No parsing beyond JSON and text bodies. No table shaping, no field extraction,
  no schema.
- No vendor-specific retry or rate-limit numbers. The package offers the
  mechanism; the client supplies the policy.
- No worker pool. Batching covers many questions to one source. Fanning out
  across a dozen *different* services at once needs process-level concurrency
  with a daemon lifecycle, and that belongs in an application.

## Dependencies

`Imports` is `httr2`, `cachem`, `curl`, `jsonlite`, `rlang`, and `tools`, and
that is a hard constraint. Every downstream package and app inherits this list,
so anything added here is added everywhere. A dependency that looks harmless in
a transport layer becomes a transitive dependency of every application that
installs it, and of every container image those are built into.

`jsonlite` is on the list for a reason worth knowing about. httr2 carries it in
Suggests, not Imports, and `httr2::resp_body_json()` calls
`check_installed("jsonlite")` at runtime. Without it declared here, biohttp
installs cleanly and then fails on the first `get_json()` call, which is the
package's main entry point. It costs nothing in practice: `shiny` imports
`jsonlite` directly, so every consumer app already has it.

`curl` is declared because `redact_secrets()` calls `curl::curl_escape()`
directly, matching the encoder httr2 builds query strings with. It is already a
hard `Imports` of httr2, so it adds nothing to what a consumer installs; it is
named here because the package uses it rather than merely inheriting it.

`tools` is declared because `cache_dir()` calls `tools::R_user_dir()` to place
the disk cache. It ships with R itself, so it adds nothing to what a consumer
installs; it is named for the same reason `curl` is, which is that `R CMD check`
wants a declaration for anything reached with `::`.

For the set a consumer actually installs, ask rather than trust a table written
once:

```r
pak::pkg_deps("biohttp")
```

The package is pure R. There is no `src/`, and there will not be, because a call
spends its time waiting on somebody else's server rather than parsing the reply.
`CONTRIBUTING.md` has the measurement.

## Using it

`vignette("biohttp")` is the guide for client authors. The short version:

```r
res <- get_json(
  "https://mygene.info/v3",
  path = "query",
  query = list(q = "BRCA1", species = "human"),
  source = "MyGene"
)

switch(res$status,
  ok = res$data$hits,
  no_data = NULL,
  skipped = NULL,
  stop(res$error)
)
```

There is no `tryCatch()` in that, and there does not need to be. A DNS failure,
a 503, and a 200 carrying an HTML maintenance page all come back as values.

## Citing biohttp

Each release is archived on Zenodo. Use the concept DOI, which always resolves
to the newest release:

> Bharti, S. (2026). *biohttp: Normalized HTTP Transport with Circuit Breaking
> and Caching*. Zenodo. <https://doi.org/10.5281/zenodo.21731864>

To pin the exact version you used, take its own DOI from `CITATION.cff`, which
carries one identifier per archived release.

`inst/CITATION` ships in the package, so `citation("biohttp")` works from an
installed copy, and `CITATION.cff` stays in the repository for the "Cite this
repository" button on GitHub.

## Contributing

See
[CONTRIBUTING.md](https://github.com/samuelbharti/biohttp/blob/main/CONTRIBUTING.md).
The scope lines above are the first thing a pull request is checked against.

## License

MIT. See
[LICENSE.md](https://github.com/samuelbharti/biohttp/blob/main/LICENSE.md).
