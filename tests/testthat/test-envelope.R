test_that("ok is derived from status and cannot disagree with it", {
  for (level in STATUS_LEVELS) {
    env <- envelope(level, source = "S")
    expect_identical(env$ok, identical(level, "ok"))
  }
})

test_that("envelope rejects a status outside the enum", {
  expect_error(envelope("broken", source = "S"))
  expect_error(envelope(NA_character_))
  expect_error(envelope(character(0)))
  expect_error(envelope(c("ok", "error")))
})

test_that("envelope does not partial-match a status", {
  # match.arg() would accept every one of these: "t" becomes timeout, "sk"
  # becomes skipped, "err" becomes error. A status is a contract, so a typo has
  # to fail loudly rather than quietly produce a different outcome.
  for (typo in c("t", "sk", "err", "no_d", "rate")) {
    expect_error(envelope(typo), "must be one of")
  }
})

test_that("an envelope carries the user message apart from the log detail", {
  env <- status_error(
    source = "S",
    http = 503L,
    error = "S is temporarily unavailable.",
    detail = "curl: (7) Failed to connect to s.test port 443"
  )
  # The split is the point: an app renders `error` and logs `detail`, so a
  # stack trace never reaches a user and the log never loses one.
  expect_identical(env$error, "S is temporarily unavailable.")
  expect_match(env$detail, "curl", fixed = TRUE)
  expect_false(grepl("curl", env$error, fixed = TRUE))
})

test_that("every constructor produces its own status", {
  expect_identical(status_ok(data = list(x = 1))$status, "ok")
  expect_identical(status_no_data()$status, "no_data")
  expect_identical(status_stale(data = list(x = 1))$status, "stale")
  expect_identical(status_rate_limited()$status, "rate_limited")
  expect_identical(status_timeout()$status, "timeout")
  expect_identical(status_skipped()$status, "skipped")
  expect_identical(status_error()$status, "error")
})

test_that("classify_http maps only the codes the transport owns", {
  expect_identical(classify_http(200L), "ok")
  expect_identical(classify_http(204L), "ok")
  expect_identical(classify_http(404L), "no_data")
  expect_identical(classify_http(408L), "timeout")
  expect_identical(classify_http(429L), "rate_limited")
  expect_identical(classify_http(500L), "error")
  expect_identical(classify_http(503L), "error")
  expect_identical(classify_http(NA), "error")
  expect_identical(classify_http("not a code"), "error")
})

test_that("classify_condition separates a timeout from everything else", {
  expect_identical(
    classify_condition(simpleError("Timeout was reached")),
    "timeout"
  )
  expect_identical(
    classify_condition(simpleError("Operation timed out after 20000 ms")),
    "timeout"
  )
  # A DNS failure and a timeout read very differently to a user deciding
  # whether it is worth trying again.
  expect_identical(
    classify_condition(simpleError("Could not resolve host: x.test")),
    "error"
  )
})

test_that("body_or_null gives the body for ok and for stale", {
  expect_identical(body_or_null(status_ok(data = list(n = 1)))$n, 1)

  # A stale envelope carries real data that is merely past its freshness
  # window. Returning NULL for it would throw away the one thing the caller
  # asked for.
  expect_identical(body_or_null(status_stale(data = list(n = 2)))$n, 2)

  expect_null(body_or_null(status_error()))
  expect_null(body_or_null(status_no_data()))
  expect_null(body_or_null(status_skipped()))
  expect_null(body_or_null(status_timeout()))
  expect_null(body_or_null(status_rate_limited()))
})

test_that("stale is still never cached, despite carrying a body", {
  # ok stays FALSE for stale, which is what keeps cached() from storing it.
  expect_false(status_stale(data = list(n = 1))$ok)
})
