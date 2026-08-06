## What this changes

## Why

## Checks run locally

CI runs on a pull request into `dev` or `main`, but it runs after the fact. The
local run is what keeps a broken commit off the branch. See `CONTRIBUTING.md`.

- [ ] `prek run --all-files`
- [ ] `Rscript -e 'devtools::test()'`
- [ ] `Rscript -e 'rcmdcheck::rcmdcheck(args = c("--no-manual", "--as-cran"))'`

## Scope

- [ ] Stays inside the lines in `CONTRIBUTING.md`: no Shiny, no
      service-specific knowledge, no parsing beyond JSON and text, no
      vendor-specific retry or rate-limit numbers.
- [ ] No new entry in `Imports`, or it was agreed on an issue first.

## If it touches behaviour

- [ ] A test covers it, and the test fails without the change.
- [ ] `NEWS.md` says what changed.
- [ ] `devtools::document()` was run and `man/` is in sync.
