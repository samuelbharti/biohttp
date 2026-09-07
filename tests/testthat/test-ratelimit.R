test_that("a host with no recorded pause waits for nothing", {
  ratelimit_reset()
  waited <- ratelimit_wait("host.test", sleep = function(s) {
    stop("should not sleep")
  })
  expect_identical(waited, 0)
})

test_that("recording a pause makes the next wait sleep for it", {
  ratelimit_reset()
  ratelimit_record("host.test", retry_after = 5, now = 1000)

  slept <- numeric()
  waited <- ratelimit_wait(
    "host.test",
    now = 1000,
    sleep = function(s) slept <<- c(slept, s)
  )

  expect_equal(waited, 5)
  expect_equal(slept, 5)
  ratelimit_reset()
})

test_that("a NULL or NA retry_after falls back to the default pause", {
  ratelimit_reset()
  withr::local_envvar(BIOHTTP_RATELIMIT_DEFAULT_PAUSE = "7")

  ratelimit_record("a.test", retry_after = NULL, now = 1000)
  ratelimit_record("b.test", retry_after = NA_real_, now = 1000)

  expect_equal(
    ratelimit_wait("a.test", now = 1000, sleep = function(s) NULL),
    7
  )
  expect_equal(
    ratelimit_wait("b.test", now = 1000, sleep = function(s) NULL),
    7
  )
  ratelimit_reset()
})

test_that("a later, shorter pause does not shorten an existing one", {
  # Of several retryable responses in one batch, the longest asked-for wait
  # wins: a second record() call for the same host must never move
  # pause_until earlier.
  ratelimit_reset()
  ratelimit_record("host.test", retry_after = 30, now = 1000)
  ratelimit_record("host.test", retry_after = 2, now = 1000)

  waited <- ratelimit_wait("host.test", now = 1000, sleep = function(s) NULL)
  expect_equal(waited, 30)
  ratelimit_reset()
})

test_that("an elapsed pause waits for nothing", {
  ratelimit_reset()
  ratelimit_record("host.test", retry_after = 5, now = 1000)

  waited <- ratelimit_wait(
    "host.test",
    now = 1010,
    sleep = function(s) stop("should not sleep")
  )
  expect_identical(waited, 0)
  ratelimit_reset()
})

test_that("ratelimit_reset clears every host", {
  ratelimit_record("a.test", retry_after = 5, now = 1000)
  ratelimit_record("b.test", retry_after = 5, now = 1000)
  ratelimit_reset()

  expect_identical(
    ratelimit_wait("a.test", now = 1000, sleep = function(s) stop("no")),
    0
  )
  expect_identical(
    ratelimit_wait("b.test", now = 1000, sleep = function(s) stop("no")),
    0
  )
})
