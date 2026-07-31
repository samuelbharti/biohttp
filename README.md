# biohttp

<!-- badges: start -->
[![R-CMD-check](https://github.com/samuelbharti/biohttp/actions/workflows/r.yml/badge.svg)](https://github.com/samuelbharti/biohttp/actions/workflows/r.yml)
<!-- badges: end -->

One HTTP transport layer for R clients of biological web services.

> **Status:** scaffold only. No transport code yet. See the roadmap below.

## Why

Four apps in this family each grew their own HTTP layer by copying the nearest
one, and the copies have drifted. A latent `.Rprofile` bug was fixed in some but
not all of them. One copy raises a condition where the other three return a
value. Every new app starts by copying whichever version was closest to hand.

biohttp is that layer extracted once, installed rather than copied, so a fix
lands in one place.

Day-one consumers:

| App | Current file |
| --- | --- |
| `multi-variant-reviewer` | `R/http.R` and `R/cache.R`. The superset, and the source of truth for the port. |
| `genescout` | `R/http.R`. Adds text and other non-JSON response handling. |
| `variant-reviewer` | `R/api_http.R`. The lineage ancestor, and the first migration target. |
| `knowledge-graph-viewer` | `R/api_http.R`. Raises instead of returning, so it needs a behavior change to adopt. |

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

## What it does not do

- No Shiny. Not in Imports, not in Suggests, not in tests.
- No service-specific knowledge. Nothing here knows what a gene is. Service
  clients live in `bioclients`.
- No parsing beyond JSON and text bodies. No table shaping, no field extraction,
  no schema.
- No vendor-specific retry or rate-limit numbers. The package offers the
  mechanism; the client supplies the policy.

## Dependencies

`Imports` is `httr2`, `cachem`, and `rlang`, and that is a hard constraint. Every
downstream package and app inherits this list, so anything added here is added
everywhere. A dependency that looks harmless in a transport layer becomes a
transitive dependency of six Shiny apps and a Docker image.

Resolved against CRAN on 2026-07-31, with `httr2` 1.3.0, `cachem` 1.1.0, and
`rlang` 1.3.0:

| Declared | Brings in directly |
| --- | --- |
| `httr2` | `cli`, `curl`, `glue`, `lifecycle`, `magrittr`, `openssl`, `R6`, `rlang`, `vctrs`, `withr` |
| `cachem` | `fastmap`, `rlang` |
| `rlang` | nothing outside base R |

The full recursive set is 13 non-base packages: `askpass`, `cli`, `curl`,
`fastmap`, `glue`, `lifecycle`, `magrittr`, `openssl`, `R6`, `rlang`, `sys`,
`vctrs`, `withr`. `askpass` and `sys` arrive under `openssl`.

Regenerate this list with:

```r
deps <- tools::package_dependencies(
  c("httr2", "cachem", "rlang"),
  which = c("Depends", "Imports", "LinkingTo"),
  recursive = TRUE
)
setdiff(sort(unique(unlist(deps))), rownames(installed.packages(priority = "base")))
```

## Installation

Not published yet. Once it is on r-universe:

```r
install.packages("biohttp", repos = "https://samuelbharti.r-universe.dev")
```

## Roadmap

| Phase | State |
| --- | --- |
| 0. Scaffold | in progress |
| 1. Port the transport from `multi-variant-reviewer` verbatim | not started |
| 2. Apply the envelope contract, write the vignette, tag 0.1.0 | not started |
| 3. Publish to r-universe, pkgdown site live | not started |
| 4. Pilot migration of `variant-reviewer`, including the Docker rebuild | not started |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The scope lines above are the first thing
a pull request is checked against.

## License

MIT. See [LICENSE.md](LICENSE.md).
