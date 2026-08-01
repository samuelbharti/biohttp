json_batch_response <- function(body, status = 200L) {
  httr2::response(
    status_code = status,
    headers = list(`content-type` = "application/json"),
    body = charToRaw(body)
  )
}

batch_reqs <- function(urls) {
  lapply(urls, function(url) req_defaults(httr2::request(url)))
}

# --- Order, which everything else depends on ---------------------------------

test_that("perform_many returns results in the order asked for", {
  breaker_reset()
  # Echo the path back so a shuffled result is visible rather than plausible.
  httr2::local_mocked_responses(function(req) {
    json_batch_response(paste0('{"path":"', basename(req$url), '"}'))
  })
  reqs <- batch_reqs(paste0("https://mock.test/", c("a", "b", "c", "d")))

  res <- perform_many(reqs, "S")

  expect_length(res, 4)
  expect_identical(
    vapply(res, function(r) r$data$path, character(1)),
    c("a", "b", "c", "d")
  )
})

test_that("perform_many on an empty list returns an empty list", {
  breaker_reset()
  expect_identical(perform_many(list(), "S"), list())
})

# --- Mixed outcomes in one batch ---------------------------------------------

test_that("one failure in a batch does not take the others down", {
  breaker_reset()
  httr2::local_mocked_responses(function(req) {
    if (grepl("bad", req$url, fixed = TRUE)) {
      return(httr2::response(status_code = 404))
    }
    json_batch_response('{"ok":true}')
  })
  reqs <- batch_reqs(paste0("https://mock.test/", c("good", "bad", "good2")))

  res <- perform_many(reqs, "S")

  expect_identical(
    vapply(res, function(r) r$status, character(1)),
    c("ok", "no_data", "ok")
  )
})

test_that("a batch classifies through the same code path as perform", {
  # The three failure classes are the reason this package exists. Two copies of
  # them is how the four app-local layers drifted apart, so the batched path
  # must call the same classifier rather than growing its own.
  expect_true(is.function(classify_result))
  expect_identical(
    names(formals(classify_result)),
    c("resp", "source", "host", "read_body")
  )
})

test_that("classify_result turns a transport condition into a timeout", {
  breaker_reset()
  res <- classify_result(
    simpleError("Timeout was reached after 20000 ms"),
    "S",
    "mock.test",
    read_json_body
  )
  expect_identical(res$status, "timeout")
  expect_true(is.na(res$http))
  breaker_reset()
})

# --- The breaker -------------------------------------------------------------

test_that("an open breaker skips a host without dispatching anything", {
  breaker_reset()
  for (i in seq_len(breaker_threshold())) {
    breaker_record("down.test", reachable = FALSE)
  }
  # No mock is installed, so a dispatched request would attempt the network.
  # skipped for every entry proves none went out.
  reqs <- batch_reqs(paste0("https://down.test/", c("a", "b", "c")))

  res <- perform_many(reqs, "S")

  expect_identical(
    vapply(res, function(r) r$status, character(1)),
    c("skipped", "skipped", "skipped")
  )
  expect_match(res[[1]]$detail, "breaker open")
  breaker_reset()
})

test_that("one host's open breaker does not skip another host", {
  breaker_reset()
  for (i in seq_len(breaker_threshold())) {
    breaker_record("down.test", reachable = FALSE)
  }
  httr2::local_mocked_responses(function(req) {
    json_batch_response('{"ok":true}')
  })
  reqs <- batch_reqs(c(
    "https://down.test/a",
    "https://up.test/b",
    "https://down.test/c"
  ))

  res <- perform_many(reqs, "S")

  expect_identical(
    vapply(res, function(r) r$status, character(1)),
    c("skipped", "ok", "skipped")
  )
  breaker_reset()
})

test_that("a non-2xx inside a batch does not count against the host", {
  breaker_reset()
  httr2::local_mocked_responses(function(req) {
    httr2::response(status_code = 503)
  })
  reqs <- batch_reqs(paste0(
    "https://mock.test/",
    seq_len(breaker_threshold() + 1L)
  ))

  res <- perform_many(reqs, "S")

  expect_true(all(vapply(res, function(r) r$status, character(1)) == "error"))
  expect_false(breaker_open("mock.test"))
  breaker_reset()
})

# --- The cache, which is where batching actually pays -------------------------

test_that("get_json_many performs only the entries the cache is missing", {
  breaker_reset()
  cache_reset()
  calls <- 0L
  httr2::local_mocked_responses(function(req) {
    calls <<- calls + 1L
    json_batch_response('{"ok":true}')
  })
  queries <- list(list(q = "A"), list(q = "B"), list(q = "C"))

  first <- get_json_many("https://mock.test", "query", queries, source = "S")
  expect_length(first, 3)
  expect_identical(calls, 3L)

  # Same three again: entirely warm, so nothing goes out.
  get_json_many("https://mock.test", "query", queries, source = "S")
  expect_identical(calls, 3L)

  # Two warm, one new. Only the new one is fetched.
  get_json_many(
    "https://mock.test",
    "query",
    list(list(q = "A"), list(q = "D"), list(q = "C")),
    source = "S"
  )
  expect_identical(calls, 4L)
})

test_that("a batch and a single call share cache entries both ways", {
  # The keys have to be built identically or a warm entry is invisible to the
  # other entry point, which would quietly double the request count.
  breaker_reset()
  cache_reset()
  calls <- 0L
  httr2::local_mocked_responses(function(req) {
    calls <<- calls + 1L
    json_batch_response('{"ok":true}')
  })

  get_json(
    "https://mock.test",
    path = "query",
    query = list(q = "A"),
    source = "S"
  )
  expect_identical(calls, 1L)

  get_json_many(
    "https://mock.test",
    "query",
    list(list(q = "A")),
    source = "S"
  )
  expect_identical(calls, 1L)

  get_json_many(
    "https://mock.test",
    "query",
    list(list(q = "Z")),
    source = "S"
  )
  expect_identical(calls, 2L)

  get_json(
    "https://mock.test",
    path = "query",
    query = list(q = "Z"),
    source = "S"
  )
  expect_identical(calls, 2L)
})

test_that("a failed entry in a batch is never cached", {
  # The single most important cache rule in the package, asserted for the
  # batched path too. A stored failure poisons itself for the life of the
  # process.
  breaker_reset()
  cache_reset()
  calls <- 0L
  httr2::local_mocked_responses(function(req) {
    calls <<- calls + 1L
    if (grepl("q=BAD", req$url, fixed = TRUE)) {
      return(httr2::response(status_code = 503))
    }
    json_batch_response('{"ok":true}')
  })
  queries <- list(list(q = "GOOD"), list(q = "BAD"))

  get_json_many("https://mock.test", "query", queries, source = "S")
  expect_identical(calls, 2L)

  # The good one is warm, the failed one is retried.
  get_json_many("https://mock.test", "query", queries, source = "S")
  expect_identical(calls, 3L)
})

test_that("post_json_many keys on the body, not just the url", {
  breaker_reset()
  cache_reset()
  calls <- 0L
  httr2::local_mocked_responses(function(req) {
    calls <<- calls + 1L
    json_batch_response('{"data":{}}')
  })
  url <- "https://mock.test/graphql"

  post_json_many(
    url,
    bodies = list(list(query = "one"), list(query = "two")),
    source = "S"
  )
  expect_identical(calls, 2L)

  post_json_many(
    url,
    bodies = list(list(query = "one"), list(query = "three")),
    source = "S"
  )
  expect_identical(calls, 3L)
})

# --- Argument handling -------------------------------------------------------

test_that("path is recycled across queries, or matched one to one", {
  breaker_reset()
  cache_reset()
  seen <- character()
  httr2::local_mocked_responses(function(req) {
    seen <<- c(seen, req$url)
    json_batch_response('{"ok":true}')
  })

  get_json_many(
    "https://mock.test",
    "query",
    list(list(q = "A"), list(q = "B")),
    source = "S"
  )
  expect_true(all(grepl("/query", seen, fixed = TRUE)))

  seen <- character()
  get_json_many(
    "https://mock.test",
    c("one", "two"),
    list(list(q = "A"), list(q = "B")),
    source = "S"
  )
  expect_match(seen[1], "/one")
  expect_match(seen[2], "/two")
})

test_that("a path vector of the wrong length is an error, not a recycle", {
  expect_error(
    get_json_many(
      "https://mock.test",
      c("one", "two", "three"),
      list(list(q = "A"), list(q = "B")),
      source = "S"
    ),
    "must be length 1 or 2"
  )
})
