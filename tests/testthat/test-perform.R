json_response <- function(body, status = 200L) {
  httr2::response(
    status_code = status,
    headers = list(`content-type` = "application/json"),
    body = charToRaw(body)
  )
}

test_that("perform returns ok with the parsed body on a 2xx", {
  breaker_reset()
  httr2::local_mocked_responses(list(json_response('{"a":1,"b":[2,3]}')))
  res <- perform(req_defaults(httr2::request("https://mock.test/x")), "S")

  expect_true(res$ok)
  expect_identical(res$status, "ok")
  expect_equal(res$http, 200)
  expect_equal(res$data$a, 1)
  expect_identical(res$source, "S")
})

test_that("perform classifies non-2xx responses onto the enum", {
  breaker_reset()
  req <- req_defaults(httr2::request("https://mock.test/x"))

  httr2::local_mocked_responses(list(httr2::response(status_code = 404)))
  expect_identical(perform(req, "S")$status, "no_data")

  httr2::local_mocked_responses(list(httr2::response(status_code = 429)))
  expect_identical(perform(req, "S")$status, "rate_limited")

  httr2::local_mocked_responses(list(httr2::response(status_code = 503)))
  expect_identical(perform(req, "S")$status, "error")
})

test_that("perform never throws on a transport failure", {
  breaker_reset()
  testthat::local_mocked_bindings(
    req_perform = function(req, ...) stop("Could not resolve host: mock.test"),
    .package = "httr2"
  )
  res <- perform(req_defaults(httr2::request("https://mock.test/x")), "S")

  expect_false(res$ok)
  expect_identical(res$status, "error")
  expect_true(is.na(res$http))
  expect_match(res$detail, "Could not reach S", fixed = TRUE)
  breaker_reset()
})

test_that("a transport timeout classifies as timeout, not a generic error", {
  breaker_reset()
  testthat::local_mocked_bindings(
    req_perform = function(req, ...) stop("Timeout was reached after 20000 ms"),
    .package = "httr2"
  )
  res <- perform(req_defaults(httr2::request("https://mock.test/x")), "S")
  expect_identical(res$status, "timeout")
  breaker_reset()
})

# --- The three failure classes, and which of them touches the breaker --------
# This is the rule the four app-local layers disagreed about, so each class gets
# its own assertion about the breaker rather than one combined test.

test_that("only a transport failure counts against the breaker", {
  breaker_reset()
  testthat::local_mocked_bindings(
    req_perform = function(req, ...) stop("Could not resolve host: mock.test"),
    .package = "httr2"
  )
  req <- req_defaults(httr2::request("https://mock.test/x"))
  for (i in seq_len(breaker_threshold())) {
    perform(req, "S")
  }
  expect_true(breaker_open("mock.test"))
  breaker_reset()
})

test_that("a non-2xx does not count against the breaker", {
  breaker_reset()
  req <- req_defaults(httr2::request("https://mock.test/x"))
  # A 503 means the host answered. It is unhealthy, not unreachable, and taking
  # it out of rotation for that would turn a partial outage into a total one.
  httr2::local_mocked_responses(function(req) {
    httr2::response(status_code = 503)
  })
  for (i in seq_len(breaker_threshold() + 1L)) {
    expect_identical(perform(req, "S")$status, "error")
  }
  expect_false(breaker_open("mock.test"))
  breaker_reset()
})

test_that("a 2xx with an unreadable body is a data error, not a bad host", {
  breaker_reset()
  req <- req_defaults(httr2::request("https://mock.test/x"))
  # A 200 whose body is not JSON: an HTML maintenance page, a proxy
  # interstitial. The host answered, so this classifies as a data error
  # carrying the real code, and it must never count against the host, even
  # repeated past the breaker threshold.
  httr2::local_mocked_responses(function(req) {
    json_response("<html>maintenance</html>")
  })
  for (i in seq_len(breaker_threshold() + 1L)) {
    res <- perform(req, "S")
    expect_identical(res$status, "error")
    expect_equal(res$http, 200)
    expect_match(res$detail, "unreadable body")
  }
  expect_false(breaker_open("mock.test"))
  breaker_reset()
})

test_that("perform short-circuits to skipped when the breaker is open", {
  breaker_reset()
  for (i in seq_len(breaker_threshold())) {
    breaker_record("mock.test", reachable = FALSE)
  }
  # No mock is installed, so a real request would go out. skipped proves none
  # did.
  res <- perform(req_defaults(httr2::request("https://mock.test/x")), "S")
  expect_identical(res$status, "skipped")
  expect_match(res$detail, "breaker open")
  breaker_reset()
})

# --- The text variant --------------------------------------------------------

test_that("perform_text returns the body verbatim in data", {
  breaker_reset()
  body <- "gene\tclassification\nBRCA1\tDefinitive\n"
  httr2::local_mocked_responses(list(httr2::response(
    status_code = 200,
    body = charToRaw(body)
  )))
  res <- perform_text(
    req_defaults(httr2::request("https://mock.test/f.tsv")),
    "ClinGen"
  )

  expect_true(res$ok)
  expect_identical(res$data, body)
})

test_that("perform_text uses the same envelope and the same breaker rule", {
  breaker_reset()
  req <- req_defaults(httr2::request("https://mock.test/f.tsv"))
  httr2::local_mocked_responses(function(req) {
    httr2::response(status_code = 500)
  })
  for (i in seq_len(breaker_threshold() + 1L)) {
    expect_identical(perform_text(req, "ClinGen")$status, "error")
  }
  expect_false(breaker_open("mock.test"))
  breaker_reset()
})

# --- The convenience wrappers ------------------------------------------------

test_that("get_json drops blank query values rather than sending param=", {
  breaker_reset()
  cache_reset()
  seen <- NULL
  httr2::local_mocked_responses(function(req) {
    seen <<- req$url
    json_response('{"ok":true}')
  })
  get_json(
    "https://mock.test",
    path = "query",
    query = list(q = "BRCA1", species = NULL, build = "", fields = NA),
    source = "S"
  )

  expect_match(seen, "q=BRCA1", fixed = TRUE)
  expect_false(grepl("species", seen, fixed = TRUE))
  expect_false(grepl("build", seen, fixed = TRUE))
  expect_false(grepl("fields", seen, fixed = TRUE))
})

test_that("post_json keys the cache on the body, not just the url", {
  breaker_reset()
  cache_reset()
  calls <- 0L
  httr2::local_mocked_responses(function(req) {
    calls <<- calls + 1L
    json_response('{"ok":true}')
  })
  url <- "https://mock.test/graphql"
  post_json(url, body = list(query = "one"), source = "S")
  post_json(url, body = list(query = "two"), source = "S")
  post_json(url, body = list(query = "one"), source = "S")

  # Two distinct bodies, so two calls; the third repeats the first and is
  # served from the cache.
  expect_identical(calls, 2L)
})

test_that("two callers with different credentials do not share a cache entry", {
  # Keying on the url alone would serve one caller's response to another, which
  # for a key-gated source is somebody else's data.
  breaker_reset()
  cache_reset()
  bodies <- c('{"who":"alice"}', '{"who":"bob"}')
  calls <- 0L
  httr2::local_mocked_responses(function(req) {
    calls <<- calls + 1L
    json_response(bodies[min(calls, length(bodies))])
  })

  alice <- get_json(
    "https://mock.test",
    path = "me",
    source = "S",
    headers = list(Authorization = "Bearer alice-token")
  )
  bob <- get_json(
    "https://mock.test",
    path = "me",
    source = "S",
    headers = list(Authorization = "Bearer bob-token")
  )

  expect_identical(calls, 2L)
  expect_identical(alice$data$who, "alice")
  expect_identical(bob$data$who, "bob")
})

test_that("the same credentials still hit the cache", {
  breaker_reset()
  cache_reset()
  calls <- 0L
  httr2::local_mocked_responses(function(req) {
    calls <<- calls + 1L
    json_response('{"ok":true}')
  })
  hdrs <- list(Authorization = "Bearer same-token")

  get_json("https://mock.test", path = "me", source = "S", headers = hdrs)
  get_json("https://mock.test", path = "me", source = "S", headers = hdrs)

  expect_identical(calls, 1L)
})

test_that("perform and perform_text share one core", {
  # They differ only in how a 2xx body is read, so the breaker rule and the
  # three failure classes cannot drift apart between them. Two near-identical
  # copies is exactly how the four app-local layers diverged.
  expect_true(is.function(perform_with))
  expect_identical(
    names(formals(perform_with)),
    c("req", "source", "read_body", "secret_query")
  )
})

test_that("get_text returns a string and caches it once per url", {
  breaker_reset()
  cache_reset()
  calls <- 0L
  httr2::local_mocked_responses(function(req) {
    calls <<- calls + 1L
    httr2::response(status_code = 200, body = charToRaw("a\tb\n"))
  })
  first <- get_text("https://mock.test", path = "f.tsv", source = "S")
  second <- get_text("https://mock.test", path = "f.tsv", source = "S")

  expect_identical(first$data, "a\tb\n")
  expect_identical(second$data, "a\tb\n")
  expect_identical(calls, 1L)
})
