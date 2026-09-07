# The batched retry pass added in parallel.R: a 429 or a 503 gets one more
# chance, honoring Retry-After between passes; a settled answer (ok, no_data,
# any other 4xx) never does. `sleep` is injectable everywhere here so these
# tests assert what would have been waited for without actually waiting,
# except the one true end-to-end test at the bottom, which uses a real but
# tiny wait to prove the public API path works with nothing mocked out.

ok_response <- function() {
  httr2::response(
    status_code = 200,
    headers = list(`content-type` = "application/json"),
    body = charToRaw('{"ok":true}')
  )
}

test_that("a 429 with Retry-After is retried once, waiting the header value", {
  breaker_reset()
  ratelimit_reset()
  attempts <- 0L
  httr2::local_mocked_responses(function(req) {
    attempts <<- attempts + 1L
    if (attempts == 1L) {
      return(httr2::response(
        status_code = 429,
        headers = list(`Retry-After` = "5")
      ))
    }
    ok_response()
  })
  reqs <- list(req_defaults(httr2::request("https://mock.test/x")))
  slept <- numeric()

  res <- perform_many_with(
    reqs,
    "S",
    max_active = 6,
    progress = FALSE,
    read_body = read_json_body,
    max_tries = 3,
    sleep = function(s) slept <<- c(slept, s)
  )

  expect_identical(attempts, 2L)
  expect_identical(res[[1]]$status, "ok")
  # Recording and waiting each stamp their own Sys.time(), so the actual
  # wait is the header value minus the microseconds already spent between
  # the two calls, not exactly 5.
  expect_equal(slept, 5, tolerance = 0.01)
  ratelimit_reset()
})

test_that("a persistent 503 is capped at max_tries, not retried forever", {
  breaker_reset()
  ratelimit_reset()
  calls <- 0L
  httr2::local_mocked_responses(function(req) {
    calls <<- calls + 1L
    httr2::response(status_code = 503)
  })
  reqs <- list(req_defaults(httr2::request("https://mock.test/x")))

  res <- perform_many_with(
    reqs,
    "S",
    max_active = 6,
    progress = FALSE,
    read_body = read_json_body,
    max_tries = 3,
    base_pause = 0,
    sleep = function(s) NULL
  )

  expect_identical(calls, 3L)
  expect_identical(res[[1]]$status, "error")
  ratelimit_reset()
})

test_that("a 404 is a settled answer and is never retried", {
  breaker_reset()
  calls <- 0L
  httr2::local_mocked_responses(function(req) {
    calls <<- calls + 1L
    httr2::response(status_code = 404)
  })
  reqs <- list(req_defaults(httr2::request("https://mock.test/x")))

  res <- perform_many_with(
    reqs,
    "S",
    max_active = 6,
    progress = FALSE,
    read_body = read_json_body,
    max_tries = 3,
    sleep = function(s) stop("a settled answer must not wait for anything")
  )

  expect_identical(calls, 1L)
  expect_identical(res[[1]]$status, "no_data")
})

test_that("repeated 429s across retry passes never trip the breaker", {
  # A 429 proves the host is reachable, so breaker.R clears the count for it
  # on every one of them. That rule does not change here: pacing a
  # rate-limited host is ratelimit.R's job, not a reason to take it out of
  # rotation.
  breaker_reset()
  ratelimit_reset()
  httr2::local_mocked_responses(function(req) {
    httr2::response(status_code = 429, headers = list(`Retry-After` = "0.01"))
  })
  reqs <- list(req_defaults(httr2::request("https://mock.test/x")))

  res <- perform_many_with(
    reqs,
    "S",
    max_active = 6,
    progress = FALSE,
    read_body = read_json_body,
    max_tries = breaker_threshold() + 2L,
    sleep = function(s) NULL
  )

  expect_identical(res[[1]]$status, "rate_limited")
  expect_false(breaker_open("mock.test"))
  ratelimit_reset()
})

test_that("only the failed entries are redispatched, not the whole batch", {
  breaker_reset()
  ratelimit_reset()
  # We keep this in an environment instead of using `<<-`. lintr flags `<<-`,
  # and it grabs whatever binding it happens to find up the stack. `tries`
  # below already works this way.
  record <- new.env()
  record$seen <- character()
  tries <- new.env()
  httr2::local_mocked_responses(function(req) {
    path <- req$url
    record$seen <- c(record$seen, path)
    n <- (tries[[path]] %||% 0L) + 1L
    tries[[path]] <- n
    if (grepl("bad", path, fixed = TRUE) && n == 1L) {
      return(httr2::response(status_code = 503))
    }
    ok_response()
  })
  reqs <- list(
    req_defaults(httr2::request("https://mock.test/good1")),
    req_defaults(httr2::request("https://mock.test/bad")),
    req_defaults(httr2::request("https://mock.test/good2"))
  )

  res <- perform_many_with(
    reqs,
    "S",
    max_active = 6,
    progress = FALSE,
    read_body = read_json_body,
    max_tries = 2,
    base_pause = 0,
    sleep = function(s) NULL
  )

  expect_true(all(vapply(res, function(r) r$status, character(1)) == "ok"))
  expect_identical(sum(grepl("good1", record$seen, fixed = TRUE)), 1L)
  expect_identical(sum(grepl("good2", record$seen, fixed = TRUE)), 1L)
  expect_identical(sum(grepl("bad", record$seen, fixed = TRUE)), 2L)
  ratelimit_reset()
})

test_that("transport_stats shows a bounded retry tail, not runaway dispatch", {
  breaker_reset()
  ratelimit_reset()
  transport_stats_reset()
  httr2::local_mocked_responses(function(req) {
    httr2::response(status_code = 503)
  })
  reqs <- lapply(1:5, function(i) {
    req_defaults(httr2::request(paste0("https://mock.test/", i)))
  })

  perform_many_with(
    reqs,
    "S",
    max_active = 6,
    progress = FALSE,
    read_body = read_json_body,
    max_tries = 3,
    base_pause = 0,
    sleep = function(s) NULL
  )

  st <- transport_stats()
  expect_identical(st$dispatched, 15L)
  expect_identical(st$retried, 10L)
  transport_stats_reset()
  ratelimit_reset()
})

test_that("max_tries = 1 disables the retry pass entirely", {
  breaker_reset()
  calls <- 0L
  httr2::local_mocked_responses(function(req) {
    calls <<- calls + 1L
    httr2::response(status_code = 503)
  })
  reqs <- list(req_defaults(httr2::request("https://mock.test/x")))

  res <- perform_many_with(
    reqs,
    "S",
    max_active = 6,
    progress = FALSE,
    read_body = read_json_body,
    max_tries = 1,
    sleep = function(s) stop("must not wait when retry is disabled")
  )

  expect_identical(calls, 1L)
  expect_identical(res[[1]]$status, "error")
})

test_that("get_json_many retries a 503 chunk through the public batch API", {
  breaker_reset()
  ratelimit_reset()
  cache_reset()
  calls <- 0L
  httr2::local_mocked_responses(function(req) {
    calls <<- calls + 1L
    if (calls < 2L) {
      return(httr2::response(status_code = 503))
    }
    ok_response()
  })

  res <- get_json_many(
    "https://mock.test",
    "query",
    list(list(q = "A")),
    source = "S",
    max_tries = 3
  )

  expect_identical(res[[1]]$status, "ok")
  expect_identical(calls, 2L)
  ratelimit_reset()
  cache_reset()
})

test_that("perform_many honors max_tries end to end, with a real tiny wait", {
  # No injected sleep here: this is the one test proving the public API
  # path (perform_many -> perform_many_with -> ratelimit_wait -> Sys.sleep)
  # works with nothing mocked out. Retry-After is set to 50ms so the real
  # wait costs the suite almost nothing.
  breaker_reset()
  ratelimit_reset()
  calls <- 0L
  httr2::local_mocked_responses(function(req) {
    calls <<- calls + 1L
    if (calls < 2L) {
      return(httr2::response(
        status_code = 429,
        headers = list(`Retry-After` = "0.05")
      ))
    }
    ok_response()
  })
  reqs <- list(req_defaults(httr2::request("https://mock.test/x")))

  res <- perform_many(reqs, "S", max_tries = 3)

  expect_identical(res[[1]]$status, "ok")
  expect_identical(calls, 2L)
  ratelimit_reset()
})
