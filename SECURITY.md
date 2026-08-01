# Security policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately. Open a GitHub security
advisory on this repository, or contact the maintainer. Do not open a public
issue for a security problem.

## Credentials in requests

This package sends HTTP requests on behalf of a caller, so tokens pass through
it. Headers marked sensitive are passed to `httr2::req_headers(.redact = )`, so
the value is not printed when a request is inspected, logged, or included in an
error message. If you find a path where a redacted header leaks into visible
output, treat it as a security bug and report it as one.

Some services take their credential in the query string instead, with no header
form. NCBI E-utilities is the one this package was built against. httr2 has no
redaction for query parameters, so `secret_query` handles it here:

- The credential is attached at dispatch, inside `perform()`, so the request
  object a caller holds never contains it and neither does `print(req)`.
- It is excluded from the cache key, which is built from the URL before the
  credential is attached.
- `redact_secrets()` replaces the value in any message built from a failure,
  because a curl error normally carries the URL that failed.

A query-string credential still reaches the server's access logs, which is a
property of the service and not something a client can fix. Prefer a header when
a service offers one.

`secret_query` is for a credential that changes a rate limit or a quota. Because
it is deliberately excluded from the cache key, two calls that differ only in
their credential are treated as the same call. A credential that changes *what
comes back* must go in `headers`, which is part of the key.

## Keeping secrets out of the repository

- The package itself needs no credentials. Any token is supplied by the caller
  at request time and is never stored or written to the cache.
- Put local values in `.env`, which is gitignored.
- The `.gitignore` ignores whole categories and directories (for example
  `secrets/`, `*.key`, `*.pem`, `.env`) so that no individually sensitive
  filename has to be listed in a tracked file.
- For a file whose name itself would reveal something sensitive, add it to
  `.git/info/exclude`. That file is local and never committed.
- Three backstops run automatically. The `detect-private-key`,
  `detect-aws-credentials`, and `gitleaks` hooks all run locally on every
  commit, so a credential is caught before it becomes a commit rather than
  after it has been pushed. gitleaks then scans the full history again on a
  pull request into `main`, before anything is released.
