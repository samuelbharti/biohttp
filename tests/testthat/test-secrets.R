# A query-string credential is a different problem from a header one, and these
# pin all three halves of the difference: it must reach the wire, it must not
# reach the cache key, and it must not reach anything printable.

test_that("the secret reaches the wire", {
  breaker_reset()
  cache_reset()
  sent <- NULL
  httr2::local_mocked_responses(function(req) {
    sent <<- req$url
    httr2::response(
      status_code = 200,
      headers = list(`content-type` = "application/json"),
      body = charToRaw("{}")
    )
  })

  get_json(
    "https://eutils.test/entrez",
    path = "esearch.fcgi",
    query = list(db = "clinvar"),
    source = "ClinVar",
    secret_query = list(api_key = "SECRET123")
  )

  expect_match(sent, "api_key=SECRET123", fixed = TRUE)
  expect_match(sent, "db=clinvar", fixed = TRUE)
})

test_that("the same call with and without a key shares one cache entry", {
  # This is the whole reason the secret is excluded from the key. A rate-limit
  # credential does not change the answer, so letting it partition the cache
  # would silently discard everything already fetched the moment a key was
  # configured, and again the moment it was rotated.
  breaker_reset()
  cache_reset()
  calls <- 0L
  httr2::local_mocked_responses(function(req) {
    calls <<- calls + 1L
    httr2::response(
      status_code = 200,
      headers = list(`content-type` = "application/json"),
      body = charToRaw('{"n":1}')
    )
  })

  args <- list(
    "https://eutils.test/entrez",
    path = "esearch.fcgi",
    query = list(db = "clinvar"),
    source = "ClinVar"
  )
  do.call(get_json, args)
  do.call(get_json, c(args, list(secret_query = list(api_key = "SECRET123"))))
  do.call(get_json, c(args, list(secret_query = list(api_key = "ROTATED456"))))

  expect_identical(calls, 1L)
})

test_that("a different query is still a different cache entry", {
  # The exclusion must not go so far that it stops distinguishing real calls.
  breaker_reset()
  cache_reset()
  calls <- 0L
  httr2::local_mocked_responses(function(req) {
    calls <<- calls + 1L
    httr2::response(
      status_code = 200,
      headers = list(`content-type` = "application/json"),
      body = charToRaw("{}")
    )
  })

  for (term in c("BRCA1", "TP53")) {
    get_json(
      "https://eutils.test/entrez",
      query = list(term = term),
      source = "ClinVar",
      secret_query = list(api_key = "SECRET123")
    )
  }

  expect_identical(calls, 2L)
})

test_that("the request a caller can inspect carries no credential", {
  # req$url is what print(), a traceback, and any request logging all show.
  req <- req_defaults(httr2::request("https://eutils.test/entrez?db=clinvar"))

  expect_false(grepl("SECRET123", req$url, fixed = TRUE))
  expect_false(grepl(
    "SECRET123",
    paste(utils::capture.output(print(req)), collapse = " "),
    fixed = TRUE
  ))
})

test_that("a transport failure does not report the credential back", {
  # curl error messages normally carry the URL that failed, which is exactly
  # where the credential would be. The envelope's detail is shown to users.
  breaker_reset()
  cache_reset()
  httr2::local_mocked_responses(function(req) {
    stop("Could not resolve host: eutils.test/?db=clinvar&api_key=SECRET123")
  })

  res <- get_json(
    "https://eutils.test/entrez",
    source = "ClinVar",
    secret_query = list(api_key = "SECRET123")
  )

  expect_false(isTRUE(res$ok))
  expect_false(grepl("SECRET123", res$detail, fixed = TRUE))
  expect_match(res$detail, "<redacted>", fixed = TRUE)
})

test_that("redact_secrets replaces the value wherever it appears", {
  expect_identical(
    redact_secrets("host/?api_key=abc123 and again abc123", list(k = "abc123")),
    "host/?api_key=<redacted> and again <redacted>"
  )
})

test_that("redact_secrets leaves a message alone when there is no secret", {
  expect_identical(redact_secrets("plain message"), "plain message")
  expect_identical(redact_secrets("plain message", list()), "plain message")
  expect_identical(redact_secrets("plain message", NULL), "plain message")
})

test_that("a one-character secret is not redacted", {
  # Replacing every "a" in a message would destroy it, and a single character
  # is not a credential worth protecting.
  expect_identical(redact_secrets("a banana", list(k = "a")), "a banana")
})

test_that("a blank secret is dropped rather than sent empty", {
  breaker_reset()
  cache_reset()
  sent <- NULL
  httr2::local_mocked_responses(function(req) {
    sent <<- req$url
    httr2::response(
      status_code = 200,
      headers = list(`content-type` = "application/json"),
      body = charToRaw("{}")
    )
  })

  get_json(
    "https://eutils.test/entrez",
    query = list(db = "clinvar"),
    source = "ClinVar",
    secret_query = list(api_key = "")
  )

  expect_false(grepl("api_key", sent, fixed = TRUE))
})

test_that("the batched path applies the credential too", {
  breaker_reset()
  cache_reset()
  urls <- character()
  httr2::local_mocked_responses(function(req) {
    urls <<- c(urls, req$url)
    httr2::response(
      status_code = 200,
      headers = list(`content-type` = "application/json"),
      body = charToRaw("{}")
    )
  })

  get_json_many(
    "https://eutils.test/entrez",
    queries = list(list(term = "BRCA1"), list(term = "TP53")),
    source = "ClinVar",
    secret_query = list(api_key = "SECRET123")
  )

  expect_length(urls, 2)
  expect_true(all(grepl("api_key=SECRET123", urls, fixed = TRUE)))
})

test_that("get_text takes a credential as well", {
  # E-utilities is not the only source that ships a keyed flat file.
  breaker_reset()
  cache_reset()
  sent <- NULL
  httr2::local_mocked_responses(function(req) {
    sent <<- req$url
    httr2::response(status_code = 200, body = charToRaw("gene\tscore\n"))
  })

  get_text(
    "https://search.test",
    path = "download",
    source = "ClinGen",
    secret_query = list(token = "SECRET123")
  )

  expect_match(sent, "token=SECRET123", fixed = TRUE)
})
