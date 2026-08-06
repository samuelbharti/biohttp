# biohttp 0.1.2

This is a new submission.

## Test environments

* macOS 26 (local), R 4.6.0
* Ubuntu latest (GitHub Actions), R devel, R release, R oldrel-1
* Windows latest (GitHub Actions), R release
* macOS latest (GitHub Actions), R release

## R CMD check results

0 errors | 0 warnings | 1 note

```
* checking CRAN incoming feasibility ... NOTE
  Maintainer: 'Samuel Bharti <samuelbharti.io@gmail.com>'

  New submission
```

That note is expected for a first submission.

## Notes for the reviewer

* No example is wrapped in `\dontrun{}` or `\donttest{}`. Every example runs at
  check time in well under a second, because responses are mocked with
  `httr2::with_mocked_responses()` rather than fetched. No example, test, or
  vignette reaches the network.
* No example depends on a package in `Suggests`. No `Suggests` package name
  appears anywhere in `R/` or `man/`, and the built tarball also passes a check
  with `_R_CHECK_DEPENDS_ONLY_=true`.
* The package writes nothing outside `tempdir()` by default. The disk cache tier
  is off unless `BIOHTTP_CACHE_DISK` is set, and when it is set it writes to
  `tools::R_user_dir("biohttp", "cache")` or to a directory the caller names in
  `BIOHTTP_CACHE_DIR`.
* Examples that set an option restore it.
* `tools` is declared in `Imports` for `tools::R_user_dir()`.
* `STATUS_LEVELS` is an exported character vector, not a function. It is
  documented with `\format` and `\details` rather than `\value`, which is the
  convention for a data object. It is the only `.Rd` file with a `\usage`
  section and no `\value`; every exported function has one.
* "Nygard" in the description is an author surname, from the reference for the
  circuit breaker pattern.
* The three `https://mygene.info/v3` strings in the vignette are API base paths
  inside R code, not links. The base path answers 404 on its own by design,
  while the endpoints built from it answer 200. They are never fetched during a
  check.
