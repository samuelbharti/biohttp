test_that("the breaker trips after repeated transport failures, then heals", {
  breaker_reset()
  expect_false(breaker_open("host.test"))

  # A reachable response, whatever its status, clears the count.
  breaker_record("host.test", reachable = FALSE)
  breaker_record("host.test", reachable = TRUE)
  expect_false(breaker_open("host.test"))

  for (i in seq_len(breaker_threshold())) {
    breaker_record("host.test", reachable = FALSE)
  }
  expect_true(breaker_open("host.test"))

  # Past the cooldown the host is tried again, with no intervention.
  future <- as.numeric(Sys.time()) + breaker_cooldown() + 1
  expect_false(breaker_open("host.test", now = future))
  breaker_reset()
})

test_that("one failing host does not trip the breaker for another", {
  breaker_reset()
  for (i in seq_len(breaker_threshold())) {
    breaker_record("down.test", reachable = FALSE)
  }
  expect_true(breaker_open("down.test"))
  expect_false(breaker_open("fine.test"))
  breaker_reset()
})

test_that("breaker_reset forgets every host", {
  breaker_reset()
  for (i in seq_len(breaker_threshold())) {
    breaker_record("a.test", reachable = FALSE)
    breaker_record("b.test", reachable = FALSE)
  }
  expect_true(breaker_open("a.test"))
  expect_true(breaker_open("b.test"))

  breaker_reset()
  expect_false(breaker_open("a.test"))
  expect_false(breaker_open("b.test"))
})

test_that("the threshold and cooldown are overridable from the environment", {
  withr::local_envvar(
    BIOHTTP_BREAKER_THRESHOLD = "1",
    BIOHTTP_BREAKER_COOLDOWN = "5"
  )
  breaker_reset()
  breaker_record("quick.test", reachable = FALSE)
  expect_true(breaker_open("quick.test"))
  expect_false(breaker_open("quick.test", now = as.numeric(Sys.time()) + 6))
  breaker_reset()
})

test_that("url_host falls back rather than erroring on an unparsable url", {
  expect_identical(url_host("https://example.org/a/b?c=1"), "example.org")
  expect_identical(url_host(""), "unknown-host")
})
