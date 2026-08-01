# Contributing to biohttp

Thanks for helping. This guide covers the workflow and the local tooling.

## What belongs here

biohttp is the transport layer, and nothing else. Before opening a pull request,
check that the change fits inside these lines:

- No Shiny, in Imports, in Suggests, or in tests.
- No service-specific knowledge. Nothing here knows what a gene is. That belongs
  in a client package built on top.
- No parsing beyond JSON and text bodies. No table shaping, no field extraction,
  no schema.
- No vendor-specific retry or rate-limit numbers. The package offers the
  mechanism; the client supplies the policy.

## Dependencies

`Imports` is `httr2`, `cachem`, `jsonlite`, and `rlang`. That is a hard
constraint, not a preference. Every downstream package and app inherits this
list, so anything added here is added everywhere. A test asserts the list, so
adding one fails the suite on purpose. Adding a dependency is a discussion on an
issue first, not a commit.

`jsonlite` is there because httr2 keeps it in Suggests and
`httr2::resp_body_json()` checks for it at runtime, so without it `get_json()`
fails on a clean install.

## No compiled code

The package is pure R and stays that way. There is no `src/`, no C, no C++, and
no Rust.

This was measured, not assumed. Against the live MyGene API a call spends about
210 ms on the network and 0.2 ms parsing the response. Even on a 455 KB payload,
parsing is roughly 6% of a call. `biohttp` is I/O bound by construction, so a
faster native parser optimizes the wrong end of the problem, and native code
would put a toolchain requirement into every consumer's Docker build.

If a JSON bottleneck ever does appear, `yyjsonr` and `RcppSimdJson` already give
roughly 10x over jsonlite in C and C++ that every build environment handles
today. Reach for one of those before proposing a compiled language here.

## Branches and commits

- `dev` is the integration branch. **Every pull request targets `dev`**, not
  `main`. `dev` is merged into `main` at a release.
- Do not commit to `main` or `dev` directly. The `no-commit-to-branch` hook
  blocks it locally.
- Name branches with a type prefix: `feat/<slug>`, `fix/<slug>`, or
  `chore/<slug>`.
- Use Conventional Commit messages, for example `feat: add throttle argument`.
  Keep commits small and focused. The commit-msg hook checks the format.
- The PR title also follows Conventional Commits. A CI check enforces it.

## Local setup

Install the git hooks once:

```sh
prek install --install-hooks
prek install --hook-type commit-msg
```

Then before every push:

```sh
prek run --all-files
```

The hooks run air for R formatting plus a set of general checks. CI additionally
runs `R CMD check` on five platforms, lintr, and gitleaks.

## Tests

Tests are offline. No test hits a real host, and CI runs with no network. Use
`webfakes` to serve fixtures.

Three things get an explicit, obviously named test, because they are the rules
a hand-rolled HTTP layer most often gets wrong:

1. Only a transport failure trips the circuit breaker. A 5xx or an unreadable
   body does not, because a response in hand proves the host is reachable.
2. A failed call is never cached.
3. A header passed as sensitive never appears in a printed request or in an
   error message.

## Secrets

Never commit secrets. Put local values in `.env`, which is gitignored. For a
file whose name is itself sensitive, add it to `.git/info/exclude`, which is
never committed, rather than to `.gitignore`. See `SECURITY.md`.
