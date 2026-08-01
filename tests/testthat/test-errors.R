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
