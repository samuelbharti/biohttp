# Batched requests.
#
# One question per request is the wrong unit for most of the clients this
# serves. A gene list, a variant list, a panel: the shape is nearly always many
# questions to ONE source, and asking them one at a time spends the round trip
# over and over on a call that is already 99.9% waiting.
#
# WHAT THIS IS FOR, AND WHAT IT IS NOT.
#
# httr2 documents req_perform_parallel() as applying req_throttle() and
# req_retry() ACROSS the whole list rather than per request, and says so
# plainly: "This makes it most suitable for performing many parallel requests to
# the same host, rather than a mix of different hosts." A throttled request to
# one host would make an unthrottled request to another wait behind it.
#
# So this file batches within a host, and it groups by host to keep that true
# even when a caller passes a mixed list. Host groups run one after another. A
# caller that wants a dozen DIFFERENT services answered at once wants process
# level concurrency, not this: one daemon per host, through something like
# mirai. That belongs in an app, because it needs a daemon pool with a
# lifecycle, and this package does not manage one.
#
# The other documented limitation is that max_tries is not respected under
# parallel, and that httr2's own circuit breaker never fires there. The second
# half is why biohttp carries its own breaker (see breaker.R), and this file
# drives it explicitly: checked before dispatch, recorded after. The first
# half (max_tries) is why this file also drives its own capped retry over
# failed indices, honoring Retry-After through ratelimit.R rather than
# leaving httr2's disarmed req_retry() to not do it. See perform_many_with().

# Group indices by host, preserving first-seen host order so a batch is
# reproducible.
group_by_host <- function(hosts) {
  split(seq_along(hosts), factor(hosts, levels = unique(hosts)))
}

#' Perform many requests as one batch
#'
#' For many questions to one source. Returns a list of envelopes the same length
#' as `reqs` and **in the same order**, so a caller zips the results back onto
#' whatever it asked about by position.
#'
#' Each request must already have been through [req_defaults()], the same as for
#' [perform()].
#'
#' @section Same host, not a mix:
#' httr2 applies `req_throttle()` and `req_retry()` across the whole list rather
#' than per request, so a throttled request to one host makes an unthrottled
#' request to another wait behind it. Requests are therefore grouped by host and
#' each group is dispatched separately, which keeps each host's throttle bucket
#' honest but means host groups run one after another.
#'
#' Pass requests for one host. To query many different services at once, use
#' process-level concurrency in the application instead.
#'
#' @section Supply a throttle:
#' httr2's own advice is never to perform in parallel without `req_throttle()`,
#' because it is otherwise very easy to flood a source with simultaneous
#' requests. `req_defaults()` takes a `throttle` argument and defaults its realm
#' to the request's host. Use it. Public biological data sources are typically
#' run on a research budget.
#'
#' @section The breaker acts between batches, not inside one:
#' A host with an open breaker is never dispatched to, and every one of its
#' requests comes back `skipped`. But once a batch is in flight, a failure on the
#' first request cannot short-circuit the rest, because they have already been
#' sent. Transport failures within a batch are recorded, so they take effect on
#' the next call rather than the current one.
#'
#' @section Retry over failed indices, not the whole batch:
#' httr2 documents `req_retry()` as not firing under `req_perform_parallel()`,
#' so this function drives its own: a pass after the first re-sends only the
#' requests that came back `rate_limited`, `timeout`, or a 5xx. A settled
#' answer (`ok`, `no_data`, any other 4xx) is never retried. Before a retry
#' pass, the host's recorded pause is honored (see [ratelimit_wait()]), set
#' from that pass's `Retry-After` when a 429 or 503 sent one, or an
#' exponential backoff otherwise. See [transport_stats()] to see what a call
#' actually dispatched.
#'
#' @param reqs A list of httr2 requests, each prepared with [req_defaults()].
#' @param source A friendly label for the service, used in the user-facing
#'   message. For example `"MyGene"`.
#' @param max_active Maximum requests in flight at once.
#' @param progress Passed to `httr2::req_perform_parallel()`. `FALSE` by
#'   default, because the usual caller is a Shiny app that renders its own.
#' @param secret_query A named list of query-string credentials, applied to
#'   every request in the batch at dispatch. See [redact_secrets()].
#' @param max_tries Total attempts per host group, including the first.
#'   `1` disables the retry pass entirely.
#'
#' @return A list of envelopes, the same length and order as `reqs`. See
#'   [envelope()].
#'
#' @examples
#' breaker_reset()
#' reqs <- lapply(
#'   c("BRCA1", "TP53"),
#'   function(symbol) {
#'     req_defaults(httr2::request(paste0("https://mock.test/gene/", symbol)))
#'   }
#' )
#'
#' httr2::with_mocked_responses(
#'   function(req) {
#'     httr2::response(
#'       status_code = 200,
#'       headers = list(`content-type` = "application/json"),
#'       body = charToRaw('{"ok":true}')
#'     )
#'   },
#'   vapply(perform_many(reqs, "MyGene"), function(res) res$status, character(1))
#' )
#'
#' @export
perform_many <- function(
  reqs,
  source = "API",
  max_active = 6,
  progress = FALSE,
  secret_query = NULL,
  max_tries = 3
) {
  perform_many_with(
    reqs,
    source,
    max_active,
    progress,
    read_json_body,
    secret_query,
    max_tries = max_tries
  )
}

# The retry loop. Grouped by host like the dispatch itself, and re-entered
# once per pass so the breaker (checked once per host per pass, same as
# before) and the rate-limit ledger (checked before every pass, including
# the first) can both act between passes without touching an in-flight
# httr2 call. `sleep` is injectable so a test can assert the wait without
# spending it.
perform_many_with <- function(
  reqs,
  source,
  max_active,
  progress,
  read_body,
  secret_query = NULL,
  max_tries = 1L,
  base_pause = 2,
  sleep = Sys.sleep
) {
  out <- vector("list", length(reqs))
  if (length(reqs) == 0) {
    return(out)
  }

  hosts <- vapply(reqs, function(req) url_host(req$url), character(1))
  max_tries <- max(1L, as.integer(max_tries))

  for (idx in group_by_host(hosts)) {
    host <- hosts[[idx[1]]]
    todo <- idx
    for (pass in seq_len(max_tries)) {
      # The breaker is read once per pass rather than once per request, so a
      # batch cannot see a host as both open and closed partway through one
      # pass. A transport failure recorded during an earlier pass can still
      # open it before the next.
      if (breaker_open(host)) {
        for (i in todo) {
          out[[i]] <- status_skipped(
            source = source,
            detail = paste0(host, " breaker open")
          )
        }
        todo <- integer(0)
        break
      }
      # A no-op on the first pass, when nothing has recorded a pause yet.
      # On a retry pass this is where a 429's Retry-After from the previous
      # pass is actually honored.
      ratelimit_wait(host, sleep = sleep)
      # on_error = "continue" is what keeps the contract: a transport failure
      # lands in the result list as a condition instead of aborting the batch, and
      # classify_result() already knows how to read that.
      #
      # As in perform_with(), the credential is attached here at dispatch, so the
      # requests these were built from never carried it.
      resps <- httr2::req_perform_parallel(
        lapply(reqs[todo], apply_secret_query, secret_query = secret_query),
        on_error = "continue",
        progress = progress,
        max_active = max_active
      )
      results <- lapply(seq_along(todo), function(k) {
        classify_result(resps[[k]], source, host, read_body, secret_query)
      })
      for (k in seq_along(todo)) {
        out[[todo[k]]] <- results[[k]]
      }
      transport_stats_record(
        host,
        dispatched = length(todo),
        retried = if (pass > 1L) length(todo) else 0L,
        rate_limited = sum(vapply(
          results,
          function(r) identical(r$status, "rate_limited"),
          logical(1)
        ))
      )
      retryable <- vapply(results, is_retryable_envelope, logical(1))
      if (pass >= max_tries || !any(retryable)) {
        break
      }
      retry_after <- vapply(
        results[retryable],
        function(r) r$retry_after %||% NA_real_,
        numeric(1)
      )
      pause <- suppressWarnings(max(retry_after, na.rm = TRUE))
      if (!is.finite(pause) || pause <= 0) {
        pause <- base_pause * 2^(pass - 1) * stats::runif(1, 0.8, 1.2)
      }
      ratelimit_record(host, retry_after = pause)
      todo <- todo[retryable]
    }
  }
  out
}

# rate_limited and timeout are always worth another try. A 5xx classifies as
# "error" with the code preserved in $http, so the retryable ones are named
# explicitly here, matching is_transient() in request.R. Any other 4xx is a
# settled answer (a 404 is no_data, not this) and is never retried.
is_retryable_envelope <- function(r) {
  r$status %in%
    c("rate_limited", "timeout") ||
    (identical(r$status, "error") &&
      isTRUE(r$http %in% c(500L, 502L, 503L, 504L)))
}

# Recycle a length-1 argument across n requests, or pass through a vector that
# is already the right length. Anything else is a caller error worth naming.
recycle_arg <- function(x, n, what) {
  if (is.null(x)) {
    return(vector("list", n))
  }
  if (length(x) == 1L) {
    return(rep(list(x[[1]]), n))
  }
  if (length(x) != n) {
    stop(
      "`",
      what,
      "` must be length 1 or ",
      n,
      ", not ",
      length(x),
      call. = FALSE
    )
  }
  as.list(x)
}

# Split a keyed batch into cache hits and misses, perform only the misses, store
# the successes, and merge everything back into the caller's order.
#
# This is the half of batching that actually pays. A warm gene list becomes zero
# requests, and a half-warm one becomes only as many as are genuinely unknown.
# The keys are built exactly the way get_json() and post_json() build theirs, so
# a batch reuses entries a single call warmed and the other way around.
cached_many <- function(
  keys,
  reqs,
  source,
  max_active,
  progress,
  read_body,
  secret_query = NULL,
  max_tries = 3,
  ttl = NULL
) {
  ttl <- check_ttl(ttl)
  hits <- lapply(keys, cache_get)
  miss <- which(vapply(hits, is.null, logical(1)))
  if (length(miss) == 0) {
    return(hits)
  }
  # Two positions asking the identical question are one request, not two. A
  # repeated gene in a list is common enough to be worth collapsing, and the
  # cache cannot do it here: the requests in a batch are in flight together, so
  # the second one is dispatched long before the first has an entry to serve.
  miss_keys <- unlist(keys[miss], use.names = FALSE)
  distinct <- !duplicated(miss_keys)
  send <- miss[distinct]

  fetched <- perform_many_with(
    reqs[send],
    source,
    max_active,
    progress,
    read_body,
    secret_query,
    max_tries = max_tries
  )

  # Every position that asked gets the answer, including the ones whose request
  # was never sent.
  slot <- match(miss_keys, miss_keys[distinct])
  for (k in seq_along(miss)) {
    hits[[miss[k]]] <- fetched[[slot[k]]]
  }
  for (j in seq_along(send)) {
    # Same rule as cached(): only a success is ever stored.
    if (isTRUE(fetched[[j]]$ok)) {
      cache_set(keys[[send[j]]], fetched[[j]], ttl)
    }
  }
  hits
}

#' GET many JSON endpoints as one batch
#'
#' The batched counterpart to [get_json()]. Assembles one request per entry in
#' `queries`, serves whatever the cache already holds, performs only the rest,
#' and caches the successes.
#'
#' Send requests for one host, and pass a `throttle`. [perform_many()] explains
#' both.
#'
#' @param base_url The service's base URL.
#' @param path A path appended to `base_url`. Length 1 to use the same path for
#'   every request, or one per entry in `queries`.
#' @param queries A list of named lists, one per request. Blank values are
#'   dropped from each.
#' @inheritParams perform_many
#' @param timeout Seconds before a request is abandoned.
#' @param max_tries Total attempts, including the first. A retry pass
#'   re-sends only the entries that came back `rate_limited`, `timeout`, or
#'   a 5xx, honoring `Retry-After` between passes. See the retry section on
#'   [perform_many()].
#' @param headers A named list of headers, all marked sensitive.
#' @param throttle A throttle spec. See [req_defaults()].
#' @param ttl Seconds a cached success stays fresh, applied to every entry in
#'   the batch. `NULL`, the default, means the configured lifetime from
#'   `BIOHTTP_CACHE_TTL`. See [cached()].
#'
#' @return A list of envelopes, the same length and order as `queries`.
#'
#' @examples
#' cache_reset()
#' breaker_reset()
#'
#' httr2::with_mocked_responses(
#'   function(req) {
#'     httr2::response(
#'       status_code = 200,
#'       headers = list(`content-type` = "application/json"),
#'       body = charToRaw('{"hits":[]}')
#'     )
#'   },
#'   length(get_json_many(
#'     "https://mygene.info/v3",
#'     path = "query",
#'     queries = list(list(q = "BRCA1"), list(q = "TP53")),
#'     source = "MyGene"
#'   ))
#' )
#'
#' @export
get_json_many <- function(
  base_url,
  path = NULL,
  queries = list(),
  source = "API",
  timeout = 15,
  max_tries = 3,
  headers = NULL,
  throttle = NULL,
  max_active = 6,
  progress = FALSE,
  secret_query = NULL,
  ttl = NULL
) {
  n <- length(queries)
  paths <- recycle_arg(path, n, "path")
  reqs <- lapply(seq_len(n), function(i) {
    req <- build_get(base_url, paths[[i]], queries[[i]])
    req_defaults(req, timeout, max_tries, headers, throttle)
  })
  keys <- vapply(
    reqs,
    function(req) {
      cache_key(source, paste0("GET ", req$url), list(headers = headers))
    },
    character(1)
  )
  cached_many(
    keys,
    reqs,
    source,
    max_active,
    progress,
    read_json_body,
    secret_query,
    max_tries = max_tries,
    ttl
  )
}

#' GET many text endpoints as one batch
#'
#' The batched counterpart to [get_text()], for a source that ships several
#' flat files rather than one. Each body comes back verbatim as a string in
#' `data`, so the envelope shape matches the single call and a caller does not
#' branch on which wrapper it used.
#'
#' The keys are built exactly the way [get_text()] builds its own, so a batch
#' reuses a file a single call already fetched and the other way around.
#'
#' Send requests for one host, and pass a `throttle`. [perform_many()] explains
#' both.
#'
#' @inheritParams get_json_many
#'
#' @return A list of envelopes, the same length and order as `queries`, each
#'   with a single string in `data` on success.
#'
#' @examples
#' cache_reset()
#' breaker_reset()
#'
#' httr2::with_mocked_responses(
#'   function(req) {
#'     httr2::response(
#'       status_code = 200,
#'       body = charToRaw("gene\tscore\n")
#'     )
#'   },
#'   length(get_text_many(
#'     "https://search.clinicalgenome.org",
#'     path = c("kb/gene-validity/download", "kb/dosage/download"),
#'     queries = list(list(), list()),
#'     source = "ClinGen"
#'   ))
#' )
#'
#' @export
get_text_many <- function(
  base_url,
  path = NULL,
  queries = list(),
  source = "API",
  timeout = 30,
  max_tries = 3,
  headers = NULL,
  throttle = NULL,
  max_active = 6,
  progress = FALSE,
  secret_query = NULL,
  ttl = NULL
) {
  n <- length(queries)
  paths <- recycle_arg(path, n, "path")
  reqs <- lapply(seq_len(n), function(i) {
    req <- build_get(base_url, paths[[i]], queries[[i]])
    req_defaults(req, timeout, max_tries, headers, throttle)
  })
  keys <- vapply(
    reqs,
    function(req) {
      cache_key(
        source,
        paste0("GET_TEXT ", req$url),
        list(headers = headers)
      )
    },
    character(1)
  )
  cached_many(
    keys,
    reqs,
    source,
    max_active,
    progress,
    read_text_body,
    secret_query,
    max_tries = max_tries,
    ttl
  )
}

#' POST many JSON bodies as one batch
#'
#' The batched counterpart to [post_json()], for a JSON or GraphQL endpoint
#' answering many queries. Keyed on the URL and the body together, so two
#' different queries to the same endpoint do not collide.
#'
#' Send requests for one host, and pass a `throttle`. [perform_many()] explains
#' both.
#'
#' @param url The endpoint URL.
#' @param bodies A list of request bodies, one per request. Each is serialized
#'   as JSON.
#' @inheritParams get_json_many
#'
#' @return A list of envelopes, the same length and order as `bodies`.
#'
#' @examples
#' cache_reset()
#' breaker_reset()
#'
#' httr2::with_mocked_responses(
#'   function(req) {
#'     httr2::response(
#'       status_code = 200,
#'       headers = list(`content-type` = "application/json"),
#'       body = charToRaw('{"data":{}}')
#'     )
#'   },
#'   length(post_json_many(
#'     "https://gnomad.broadinstitute.org/api",
#'     bodies = list(list(query = "{ a }"), list(query = "{ b }")),
#'     source = "gnomAD"
#'   ))
#' )
#'
#' @export
post_json_many <- function(
  url,
  bodies = list(),
  source = "API",
  timeout = 20,
  max_tries = 3,
  headers = NULL,
  throttle = NULL,
  max_active = 6,
  progress = FALSE,
  secret_query = NULL,
  ttl = NULL
) {
  reqs <- lapply(bodies, function(body) {
    req <- httr2::req_body_json(httr2::request(url), body)
    req_defaults(req, timeout, max_tries, headers, throttle)
  })
  keys <- vapply(
    bodies,
    function(body) {
      cache_key(
        source,
        paste0("POST ", url),
        list(body = body, headers = headers)
      )
    },
    character(1)
  )
  cached_many(
    keys,
    reqs,
    source,
    max_active,
    progress,
    read_json_body,
    secret_query,
    max_tries = max_tries,
    ttl
  )
}
