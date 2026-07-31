# Retry needs a real server.
#
# httr2::local_mocked_responses() replaces the transport below the retry loop,
# so a mocked 503 is delivered exactly once no matter what max_tries says. Every
# other test file mocks, which means retry was the one piece of req_defaults()
# that nothing exercised. These tests run a local webfakes server instead, so
# they are still offline and still safe on a machine with no network.
#
# What they are really guarding: req_defaults() disarms req_error() so that
# perform() can classify a non-2xx instead of catching a condition. Disarming
# error handling is unusual enough that it is worth proving it did not also
# switch off retry.

app_process <- function() {
  skip_if_not_installed("webfakes")

  app <- webfakes::new_app()
  app$locals$flaky <- 0L
  app$locals$dead <- 0L

  # Fails twice, then succeeds. A retry policy of three or more tries should
  # get through; anything less should not.
  app$get("/flaky", function(req, res) {
    req$app$locals$flaky <- req$app$locals$flaky + 1L
    n <- req$app$locals$flaky
    code <- if (n < 3L) 503L else 200L
    res$set_status(code)$send_json(list(attempts = n), auto_unbox = TRUE)
  })

  app$get("/dead", function(req, res) {
    req$app$locals$dead <- req$app$locals$dead + 1L
    res$set_status(404)$send_json(
      list(attempts = req$app$locals$dead),
      auto_unbox = TRUE
    )
  })

  # The counters live in the server process, so the parent reads them back over
  # HTTP rather than sharing a variable.
  app$get("/count", function(req, res) {
    res$set_status(200)$send_json(
      list(flaky = req$app$locals$flaky, dead = req$app$locals$dead),
      auto_unbox = TRUE
    )
  })

  webfakes::new_app_process(app)
}

seen <- function(proc) {
  resp <- httr2::req_perform(httr2::request(proc$url("/count")))
  httr2::resp_body_json(resp)
}

test_that("a transient 503 is retried even though req_error is disarmed", {
  proc <- app_process()
  on.exit(try(proc$stop(), silent = TRUE), add = TRUE)
  breaker_reset()
  cache_reset()

  res <- perform(
    req_defaults(
      httr2::request(proc$url("/flaky")),
      max_tries = 4,
      timeout = 10
    ),
    "Flaky"
  )

  expect_identical(res$status, "ok")
  expect_equal(seen(proc)$flaky, 3)
})

test_that("a 404 is not retried, because it is a settled answer", {
  proc <- app_process()
  on.exit(try(proc$stop(), silent = TRUE), add = TRUE)
  breaker_reset()
  cache_reset()

  res <- perform(
    req_defaults(
      httr2::request(proc$url("/dead")),
      max_tries = 4,
      timeout = 10
    ),
    "Dead"
  )

  # Retrying a 404 spends someone else's capacity for an answer that will not
  # change.
  expect_identical(res$status, "no_data")
  expect_equal(seen(proc)$dead, 1)
})

test_that("a real round trip through get_json returns a parsed body", {
  # End to end against a real socket: assemble, perform, parse, cache.
  proc <- app_process()
  on.exit(try(proc$stop(), silent = TRUE), add = TRUE)
  breaker_reset()
  cache_reset()

  res <- get_json(proc$url(), path = "flaky", source = "Flaky", timeout = 10)

  expect_true(res$ok)
  expect_equal(res$http, 200)
  expect_false(is.null(res$data$attempts))
})
