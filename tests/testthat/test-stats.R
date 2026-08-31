test_that("transport_stats starts empty", {
  transport_stats_reset()
  st <- transport_stats()
  expect_s3_class(st, "data.frame")
  expect_identical(nrow(st), 0L)
  expect_identical(
    names(st),
    c("host", "dispatched", "retried", "rate_limited")
  )
})

test_that("transport_stats_record accumulates per host across calls", {
  transport_stats_reset()
  transport_stats_record(
    "a.test",
    dispatched = 3L,
    retried = 0L,
    rate_limited = 1L
  )
  transport_stats_record(
    "a.test",
    dispatched = 2L,
    retried = 2L,
    rate_limited = 0L
  )
  transport_stats_record("b.test", dispatched = 1L)

  st <- transport_stats()
  a <- st[st$host == "a.test", ]
  b <- st[st$host == "b.test", ]

  expect_identical(a$dispatched, 5L)
  expect_identical(a$retried, 2L)
  expect_identical(a$rate_limited, 1L)
  expect_identical(b$dispatched, 1L)
  transport_stats_reset()
})

test_that("a batch call actually records against the host it dispatched to", {
  transport_stats_reset()
  breaker_reset()
  httr2::local_mocked_responses(function(req) {
    httr2::response(
      status_code = 200,
      headers = list(`content-type` = "application/json"),
      body = charToRaw('{"ok":true}')
    )
  })
  reqs <- list(
    req_defaults(httr2::request("https://mock.test/a")),
    req_defaults(httr2::request("https://mock.test/b"))
  )

  perform_many(reqs, "S")

  st <- transport_stats()
  expect_identical(st$host, "mock.test")
  expect_identical(st$dispatched, 2L)
  expect_identical(st$retried, 0L)
  transport_stats_reset()
  breaker_reset()
})

test_that("transport_stats_reset clears every host", {
  transport_stats_record("a.test", dispatched = 1L)
  transport_stats_reset()
  expect_identical(nrow(transport_stats()), 0L)
})
