test_that("cache_key is stable, salt-sensitive, and a valid cachem key", {
  k1 <- cache_key("vep", "1-100-A-T", list(build = "GRCh38"))
  k2 <- cache_key("vep", "1-100-A-T", list(build = "GRCh38"))
  expect_identical(k1, k2)
  # cachem's validator allows lowercase letters and numbers only. It rejects
  # dots and dashes, so the rule is stricter than it looks and a url cannot be
  # a key directly.
  expect_match(k1, "^[a-z0-9]+$")
  expect_error(cache()$set("has.a.dot", 1))

  withr::local_envvar(BIOHTTP_CACHE_SALT = "a-different-deployment")
  k3 <- cache_key("vep", "1-100-A-T", list(build = "GRCh38"))
  expect_false(identical(k1, k3))
})

test_that("cache_key separates on every input", {
  base <- cache_key("vep", "1-100-A-T", list(build = "GRCh38"))
  by_source <- cache_key("gnomad", "1-100-A-T", list(build = "GRCh38"))
  by_key <- cache_key("vep", "1-100-A-G", list(build = "GRCh38"))
  by_params <- cache_key("vep", "1-100-A-T", list(build = "GRCh37"))

  expect_false(identical(base, by_source))
  expect_false(identical(base, by_key))
  expect_false(identical(base, by_params))
})

test_that("cached returns a stored success without refetching", {
  cache_reset()
  key <- cache_key("s", "k")
  calls <- 0L
  fetch <- function() {
    calls <<- calls + 1L
    status_ok(data = list(n = calls), source = "s")
  }
  first <- cached(key, fetch)
  second <- cached(key, fetch)

  expect_identical(calls, 1L)
  expect_identical(first$data$n, 1L)
  expect_identical(second$data$n, 1L)
})

test_that("cached never stores a failure", {
  # The rule this guards: a cache that stores an error fallback poisons itself
  # for the life of the process, and every later lookup then serves the stored
  # failure instead of retrying. So a failure is refetched every time and the
  # call count keeps climbing.
  cache_reset()
  failures <- list(
    status_error(source = "s"),
    status_no_data(source = "s"),
    status_skipped(source = "s"),
    status_timeout(source = "s"),
    status_rate_limited(source = "s"),
    status_stale(data = list(x = 1), source = "s")
  )

  for (bad in failures) {
    key <- cache_key("s", paste0("k-", bad$status))
    calls <- 0L
    fetch <- function() {
      calls <<- calls + 1L
      bad
    }
    cached(key, fetch)
    cached(key, fetch)
    expect_identical(calls, 2L)
  }
})

test_that("every status level round-trips through the store intact", {
  cache_reset()
  envelopes <- list(
    status_ok(data = list(x = 1)),
    status_no_data(),
    status_stale(data = list(x = 1)),
    status_rate_limited(),
    status_timeout(),
    status_skipped(),
    status_error()
  )
  for (env in envelopes) {
    key <- cache_key("s", env$status)
    cache()$set(key, env)
    back <- cache()$get(key)
    expect_identical(back$status, env$status)
    expect_identical(back$ok, env$ok)
  }
})

test_that("the entry ceiling bounds the count, not just the bytes", {
  # max_size bounds bytes. A process answering many small responses stays well
  # under it while holding far more entries than intended, which is the case
  # this ceiling exists for.
  withr::local_envvar(BIOHTTP_CACHE_MAX_N = "2")
  cache_reset()

  for (i in 1:3) {
    cache()$set(
      cache_key("s", paste0("k", i)),
      status_ok(data = i, source = "s")
    )
  }

  expect_length(cache()$keys(), 2)
  # Least recently used goes first, so the oldest is the one dropped.
  expect_false(cache()$exists(cache_key("s", "k1")))
  expect_true(cache()$exists(cache_key("s", "k3")))
  cache_reset()
})

test_that("no entry ceiling is applied unless one is asked for", {
  # cachem's own default is Inf. Reading an unset variable must not quietly
  # introduce a bound that was never there.
  withr::local_envvar(BIOHTTP_CACHE_MAX_N = "")
  cache_reset()

  for (i in 1:5) {
    cache()$set(
      cache_key("s", paste0("n", i)),
      status_ok(data = i, source = "s")
    )
  }

  expect_length(cache()$keys(), 5)
  cache_reset()
})

test_that("the disk tier is off unless it is asked for", {
  # A library should not start writing to somebody's disk because they
  # installed it.
  withr::local_envvar(BIOHTTP_CACHE_DISK = "")
  cache_reset()
  expect_identical(class(cache())[1], "cache_mem")
  cache_reset()
})

test_that("the disk tier defaults to the user cache directory", {
  # The default used to be a relative path, which resolved against whatever
  # directory R was started in: two working directories meant two caches, and
  # CRAN policy is that a package writes outside tempdir() only where the user
  # expects it to. R_user_dir() is per-user and absolute, so neither holds.
  withr::local_envvar(BIOHTTP_CACHE_DIR = NA)

  expect_identical(cache_dir(), tools::R_user_dir("biohttp", "cache"))
  # Absolute on both a POSIX path and a Windows drive letter.
  expect_match(cache_dir(), "^(/|[A-Za-z]:)")
})

test_that("a blank BIOHTTP_CACHE_DIR falls back rather than meaning here", {
  # Same rule env_num() and env_flag() already followed. Sys.getenv()'s own
  # default only fires when the name is absent, so exporting it with no value
  # used to yield "", and "" as a cache directory is the working directory:
  # precisely the write-wherever-R-started behaviour this release removes.
  withr::local_envvar(BIOHTTP_CACHE_DIR = "")

  expect_identical(cache_dir(), tools::R_user_dir("biohttp", "cache"))
})

test_that("the disk tier layers on when enabled", {
  dir <- withr::local_tempdir()
  withr::local_envvar(BIOHTTP_CACHE_DISK = "true", BIOHTTP_CACHE_DIR = dir)
  cache_reset()
  expect_identical(class(cache())[1], "cache_layered")
  cache_reset()
})

test_that("an unusable disk directory degrades to memory rather than failing", {
  # This is what lets the same code run in a container with no writable volume.
  #
  # The path is a directory under a regular file, so dir.create() fails on every
  # platform. It has to be tested this way because cachem::cache_disk() does not
  # error on a bad directory: it warns and hands back a working-looking object,
  # and only a real write finds out. A tryCatch on construction alone passes
  # this setup and still crashes in production.
  blocker <- withr::local_tempfile()
  writeLines("not a directory", blocker)
  withr::local_envvar(
    BIOHTTP_CACHE_DISK = "true",
    BIOHTTP_CACHE_DIR = file.path(blocker, "cache")
  )
  cache_reset()

  expect_no_error(store <- suppressWarnings(cache()))
  expect_identical(class(store)[1], "cache_mem")
  cache_reset()
})

test_that("a degraded cache still serves and stores in memory", {
  # Degrading has to leave a working cache, not a broken one.
  blocker <- withr::local_tempfile()
  writeLines("not a directory", blocker)
  withr::local_envvar(
    BIOHTTP_CACHE_DISK = "true",
    BIOHTTP_CACHE_DIR = file.path(blocker, "cache")
  )
  cache_reset()

  key <- cache_key("s", "degraded")
  calls <- 0L
  fetch <- function() {
    calls <<- calls + 1L
    status_ok(data = list(n = calls), source = "s")
  }
  suppressWarnings({
    cached(key, fetch)
    cached(key, fetch)
  })

  expect_identical(calls, 1L)
  cache_reset()
})

test_that("cache_reset empties the cache", {
  cache_reset()
  key <- cache_key("s", "persisted")
  cache()$set(key, status_ok(data = list(x = 1)))
  expect_false(cachem::is.key_missing(cache()$get(key)))

  cache_reset()
  expect_true(cachem::is.key_missing(cache()$get(key)))
})

test_that("a reference held across a reset still points at the live cache", {
  # Dropping the store unconditionally orphans anything a caller kept. Writes
  # through the orphan go where nothing else can see them and reads return
  # stale entries, with no error and no warning. The only symptom is a hit rate
  # quietly falling to zero.
  cache_reset()
  held <- cache()
  held$set(cache_key("s", "before"), status_ok(data = 1, source = "s"))

  cache_reset()

  expect_identical(held, cache())
  # A write through the held reference is visible to the rest of the package.
  key <- cache_key("s", "after")
  held$set(key, status_ok(data = 2, source = "s"))
  expect_false(is.null(cache_get(key)))
  cache_reset()
})

test_that("an in-place reset still clears every entry", {
  # Keeping the object must not mean keeping its contents.
  cache_reset()
  held <- cache()
  for (i in 1:3) {
    held$set(cache_key("s", paste0("e", i)), status_ok(data = i, source = "s"))
  }
  expect_length(held$keys(), 3)

  cache_reset()

  expect_length(held$keys(), 0)
  cache_reset()
})

test_that("changed settings still rebuild the store", {
  # The other half of the contract, and the reason cache_reset() cannot simply
  # always clear in place. Test isolation depends on a reset picking up a
  # changed BIOHTTP_CACHE_DIR or BIOHTTP_CACHE_DISK.
  withr::local_envvar(BIOHTTP_CACHE_DISK = "")
  cache_reset()
  memory_only <- cache()
  expect_identical(class(memory_only)[1], "cache_mem")

  dir <- withr::local_tempdir()
  withr::local_envvar(BIOHTTP_CACHE_DISK = "true", BIOHTTP_CACHE_DIR = dir)
  cache_reset()

  expect_identical(class(cache())[1], "cache_layered")
  expect_false(identical(memory_only, cache()))
  cache_reset()
})
