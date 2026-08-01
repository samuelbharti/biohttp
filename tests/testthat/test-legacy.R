test_that("as_legacy_envelope maps onto the old four-field shape", {
  suppressWarnings({
    old <- as_legacy_envelope(
      status_ok(data = list(n = 1), source = "MyGene", http = 200L)
    )
  })

  expect_true(old$ok)
  # `status` in the old shape is the HTTP code, not the enum. That collision is
  # exactly the ambiguity the new contract removes.
  expect_equal(old$status, 200)
  expect_identical(old$data$n, 1)
  expect_null(old$error)
})

test_that("a failure maps with its message and its detail", {
  suppressWarnings({
    old <- as_legacy_envelope(status_error(
      source = "gnomAD",
      http = 503L,
      error = "gnomAD is temporarily unavailable.",
      detail = "gnomAD returned HTTP 503"
    ))
  })

  expect_false(old$ok)
  expect_equal(old$status, 503)
  expect_null(old$data)
  expect_identical(old$error, "gnomAD is temporarily unavailable.")
  # variant-reviewer's call sites log detail, so dropping it would break them.
  expect_identical(old$detail, "gnomAD returned HTTP 503")
})

test_that("a transport failure carries NA where the code would be", {
  suppressWarnings({
    old <- as_legacy_envelope(status_timeout(source = "S"))
  })

  expect_false(old$ok)
  expect_true(is.na(old$status))
})

test_that("skipped flattens to a plain failure, the reason to migrate off it", {
  # The old shape has no way to say "not attempted because the breaker was
  # open". It reads as an ordinary failure, and that information is gone for
  # good once a call site is written against it.
  suppressWarnings({
    old <- as_legacy_envelope(status_skipped(source = "S"))
  })

  expect_false(old$ok)
  expect_null(old$data)
})

test_that("the deprecation warns once per session, not once per call", {
  # A migration runs this in a loop. A warning per request would bury the
  # signal it is meant to send.
  rm(list = ls(deprecation_warned), envir = deprecation_warned)

  expect_warning(as_legacy_envelope(status_ok(data = 1)), "deprecated")
  expect_no_warning(as_legacy_envelope(status_ok(data = 1)))
  expect_no_warning(as_legacy_envelope(status_error()))
})

test_that("the deprecation names a removal version", {
  rm(list = ls(deprecation_warned), envir = deprecation_warned)

  expect_warning(as_legacy_envelope(status_ok(data = 1)), "0.3.0")
})
