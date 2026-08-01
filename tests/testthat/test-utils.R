test_that("is_blank covers the shapes an empty query value arrives in", {
  expect_true(is_blank(NULL))
  expect_true(is_blank(character(0)))
  expect_true(is_blank(NA))
  expect_true(is_blank(NA_character_))
  expect_true(is_blank(""))
  expect_true(is_blank("   "))

  expect_false(is_blank("BRCA1"))
  expect_false(is_blank(0))
  expect_false(is_blank(FALSE))
  expect_false(is_blank(c("a", "b")))
})

test_that("pluck_at walks a path and falls back instead of erroring", {
  body <- list(data = list(gene = list(symbol = "BRCA1", aliases = NULL)))

  expect_identical(pluck_at(body, "data", "gene", "symbol"), "BRCA1")
  expect_null(pluck_at(body, "data", "variant", "id"))
  expect_identical(
    pluck_at(body, "data", "variant", "id", default = NA_character_),
    NA_character_
  )
  # A key that exists but holds NULL is a miss, not a value.
  expect_identical(
    pluck_at(body, "data", "gene", "aliases", default = "-"),
    "-"
  )
  expect_null(pluck_at(NULL, "data"))
  expect_null(pluck_at("not a list", "data"))
})

test_that("env_num falls back on a blank or malformed setting", {
  withr::local_envvar(BIOHTTP_TEST_NUM = "")
  expect_identical(env_num("BIOHTTP_TEST_NUM", 30), 30)

  withr::local_envvar(BIOHTTP_TEST_NUM = "not a number")
  expect_identical(env_num("BIOHTTP_TEST_NUM", 30), 30)

  # A zero or negative would silently disable a timeout or a cache, which is
  # the hardest kind of misconfiguration to notice.
  withr::local_envvar(BIOHTTP_TEST_NUM = "0")
  expect_identical(env_num("BIOHTTP_TEST_NUM", 30), 30)

  withr::local_envvar(BIOHTTP_TEST_NUM = "45")
  expect_identical(env_num("BIOHTTP_TEST_NUM", 30), 45)
})

test_that("env_flag only reads an unambiguous yes as true", {
  for (raw in c("1", "true", "TRUE", "yes", "on")) {
    withr::local_envvar(BIOHTTP_TEST_FLAG = raw)
    expect_true(env_flag("BIOHTTP_TEST_FLAG"))
  }
  for (raw in c("0", "false", "no", "off", "maybe")) {
    withr::local_envvar(BIOHTTP_TEST_FLAG = raw)
    expect_false(env_flag("BIOHTTP_TEST_FLAG"))
  }
  withr::local_envvar(BIOHTTP_TEST_FLAG = "")
  expect_false(env_flag("BIOHTTP_TEST_FLAG"))
  expect_true(env_flag("BIOHTTP_TEST_FLAG", default = TRUE))
})
