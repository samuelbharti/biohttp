test_that("the user agent carries an identity and a contact route", {
  ua <- user_agent("app-under-test", "1.2.0", email = "ops@example.org")
  expect_match(ua, "app-under-test/1.2.0", fixed = TRUE)
  expect_match(ua, "mailto:ops@example.org", fixed = TRUE)
})

test_that("the user agent omits a contact route rather than print it empty", {
  ua <- user_agent("app-under-test", "1.2.0", url = "", email = "")
  expect_identical(ua, "app-under-test/1.2.0")
  expect_no_match(ua, "mailto:")
  expect_no_match(ua, "()", fixed = TRUE)
})

test_that("the user agent reads the environment when nothing is passed", {
  withr::local_envvar(
    BIOHTTP_CALLER_IDENTITY = "from-env",
    BIOHTTP_CONTACT_EMAIL = "env@example.org",
    BIOHTTP_CONTACT_URL = "https://example.org/repo"
  )
  ua <- user_agent()
  expect_match(ua, "from-env", fixed = TRUE)
  expect_match(ua, "+https://example.org/repo", fixed = TRUE)
  expect_match(ua, "mailto:env@example.org", fixed = TRUE)
})

test_that("a blank identity in the environment still names the package", {
  # BIOHTTP_CALLER_IDENTITY exported with no value used to be taken literally,
  # so the header went out as "/0.1.2": a version with nothing in front of it,
  # which is the one thing a user agent exists to carry. Sys.getenv()'s default
  # argument only fires when the name is absent, and an empty export is how a
  # container passes through a variable the operator never filled in.
  #
  # The whole suite runs with these three exported empty, from setup.R, so this
  # went unnoticed in every other test in this file.
  withr::local_envvar(
    BIOHTTP_CALLER_IDENTITY = "",
    BIOHTTP_CONTACT_EMAIL = "",
    BIOHTTP_CONTACT_URL = ""
  )

  ua <- user_agent()
  expect_match(ua, "^biohttp/")
  expect_no_match(ua, "^/")
})

test_that("is_transient covers 429 and the standard 5xx, and nothing else", {
  for (code in c(429L, 500L, 502L, 503L, 504L)) {
    expect_true(is_transient(httr2::response(status_code = code)))
  }
  for (code in c(200L, 301L, 400L, 401L, 404L, 501L)) {
    expect_false(is_transient(httr2::response(status_code = code)))
  }
})

test_that("req_defaults never lets httr2 raise on an HTTP error", {
  req <- req_defaults(httr2::request("https://example.org"))
  # req_error(is_error = FALSE) is installed, so a 500 comes back as a response
  # object rather than a condition, which is what lets perform() classify it.
  httr2::local_mocked_responses(list(httr2::response(status_code = 500)))
  expect_no_error(httr2::req_perform(req))
})

test_that("req_defaults applies the timeout and the user agent", {
  req <- req_defaults(
    httr2::request("https://example.org"),
    timeout = 7,
    user_agent = "probe/1.0"
  )
  expect_equal(req$options$timeout_ms, 7000)
  expect_identical(req$options$useragent, "probe/1.0")
})

test_that("a sensitive header never appears in a printed request", {
  # The rule this guards: a token passed as a header must not surface in an
  # inspected request, a log line, or an error message. Header auth also keeps
  # the secret out of the URL, where it would land in an access log.
  token <- "super-secret-token-value"
  req <- req_defaults(
    httr2::request("https://example.org"),
    headers = list(Authorization = paste("Bearer", token))
  )

  printed <- paste(capture.output(print(req)), collapse = "\n")
  expect_false(grepl(token, printed, fixed = TRUE))
  expect_match(printed, "REDACTED")

  # req_dry_run() renders the wire format, which is the stronger check. It needs
  # httpuv, which is not a dependency here, and `R CMD check --as-cran` hides
  # undeclared packages, so this half skips rather than adding a dependency for
  # one assertion.
  skip_if_not_installed("httpuv")
  dry <- paste(capture.output(httr2::req_dry_run(req)), collapse = "\n")
  expect_false(grepl(token, dry, fixed = TRUE))
})

test_that("a throttle is only attached when asked for", {
  plain <- req_defaults(httr2::request("https://example.org"))
  throttled <- req_defaults(
    httr2::request("https://example.org"),
    throttle = list(capacity = 5, fill_time_s = 60)
  )
  expect_null(plain$policies$throttle_realm)
  expect_false(is.null(throttled$policies$throttle_realm))
})

test_that("a throttle realm defaults to the request's own host", {
  req <- req_defaults(
    httr2::request("https://one.test/a"),
    throttle = list(capacity = 5, fill_time_s = 60)
  )
  expect_match(req$policies$throttle_realm, "one.test")
})
