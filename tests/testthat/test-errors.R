test_that("http_error_message says something actionable per failure class", {
  expect_match(http_error_message("S", http = 404L), "No S data was found")
  expect_match(http_error_message("S", http = 429L), "busy")
  expect_match(http_error_message("S", http = 503L), "temporarily unavailable")
  expect_match(http_error_message("S", http = 418L), "Could not retrieve")

  expect_match(
    http_error_message("S", condition = simpleError("Timeout was reached")),
    "took too long"
  )
  expect_match(
    http_error_message("S", condition = simpleError("Could not resolve host")),
    "Check your connection"
  )
  expect_match(
    http_error_message("S", condition = simpleError("something odd")),
    "temporarily unavailable"
  )
})

test_that("http_error_message never leaks technical detail to a user", {
  raw <- "curl: (6) Could not resolve host: gnomad.test"
  msg <- http_error_message("gnomAD", condition = simpleError(raw))
  expect_false(grepl("curl", msg, fixed = TRUE))
  expect_false(grepl("gnomad.test", msg, fixed = TRUE))
})

test_that("every status has one sentence, and the constructors use it", {
  # These used to be two sets, one in http_error_message() and one hardcoded in
  # each constructor, and they had drifted. A constructor and the message
  # function must not be able to disagree about the same outcome.
  expect_identical(
    status_no_data(source = "S", http = 404L)$error,
    http_error_message("S", http = 404L)
  )
  expect_identical(
    status_rate_limited(source = "S")$error,
    http_error_message("S", http = 429L)
  )
  expect_identical(
    status_timeout(source = "S")$error,
    http_error_message("S", condition = simpleError("Timeout was reached"))
  )
  expect_identical(
    status_error(source = "S", http = 503L)$error,
    http_error_message("S", http = 503L)
  )
})

test_that("an override replaces the wording everywhere", {
  withr::local_options(
    biohttp.status_message = function(source, status, http, condition) {
      paste0("[", source, "/", status, "]")
    }
  )

  expect_identical(status_message("S", "timeout"), "[S/timeout]")
  expect_identical(http_error_message("S", http = 404L), "[S/no_data]")
  # The constructors route through it too, which is what the caller actually
  # renders.
  expect_identical(status_skipped(source = "S")$error, "[S/skipped]")
  expect_identical(status_error(source = "S", http = 503L)$error, "[S/error]")
})

test_that("an override reaches a message from a real performed call", {
  # Overriding the function in isolation is not the point; it has to reach the
  # envelope a caller gets back.
  breaker_reset()
  cache_reset()
  withr::local_options(
    biohttp.status_message = function(source, status, http, condition) {
      paste0("custom ", status)
    }
  )
  httr2::local_mocked_responses(function(req) {
    httr2::response(status_code = 503)
  })

  res <- get_json("https://mock.test", path = "x", source = "S")

  expect_identical(res$status, "error")
  expect_identical(res$error, "custom error")
})

test_that("an override that raises falls back instead of propagating", {
  # The package promises a call returns a value and never raises. An override
  # runs on the failure path, which is exactly where someone else's bug could
  # break that promise.
  withr::local_options(
    biohttp.status_message = function(source, status, http, condition) {
      stop("override is broken")
    }
  )

  expect_no_error(msg <- status_message("S", "timeout"))
  expect_identical(msg, "S took too long to respond. Please try again.")
})

test_that("an override returning something unusable falls back", {
  # Returning NULL for the cases you do not care about is the documented way to
  # override only some of them, so it has to be a clean fall-through.
  unusable <- list(NULL, NA_character_, character(0), c("a", "b"), 42, "")
  for (bad in unusable) {
    withr::local_options(
      biohttp.status_message = function(source, status, http, condition) bad
    )
    expect_identical(
      status_message("S", "timeout"),
      "S took too long to respond. Please try again."
    )
  }
})

test_that("ok and stale carry no message", {
  expect_null(status_message("S", "ok"))
  expect_null(status_message("S", "stale"))
})

test_that("graphql_error catches a 200 body carrying an errors array", {
  clean <- status_ok(data = list(data = list(x = 1)), source = "G")
  expect_null(graphql_error(clean, "G"))

  queried <- status_ok(data = list(errors = list(list(message = "bad"))), "G")
  err <- graphql_error(queried, "G")
  expect_false(err$ok)
  expect_identical(err$status, "error")
  expect_match(err$detail, "graphql")
})

test_that("graphql_error passes a transport failure straight through", {
  failed <- status_error(source = "G", http = 503L, detail = "G returned 503")
  expect_identical(graphql_error(failed, "G"), failed)
})
