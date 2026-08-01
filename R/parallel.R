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
# level concurrency, not this: see multi-variant-reviewer/R/parallel.R, which
# pins each host to its own mirai daemon. That belongs in an app, because it
# needs a daemon pool with a lifecycle, and this package does not manage one.
#
# The other documented limitation is that max_tries is not respected under
# parallel, and that httr2's own circuit breaker never fires there. The second
# half is why biohttp carries its own breaker (see breaker.R), and this file
# drives it explicitly: checked before dispatch, recorded after.

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
#' @param reqs A list of httr2 requests, each prepared with [req_defaults()].
#' @param source A friendly label for the service, used in the user-facing
#'   message. For example `"MyGene"`.
#' @param max_active Maximum requests in flight at once.
#' @param progress Passed to `httr2::req_perform_parallel()`. `FALSE` by
#'   default, because the usual caller is a Shiny app that renders its own.
#' @param secret_query A named list of query-string credentials, applied to
#'   every request in the batch at dispatch. See [redact_secrets()].
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
  secret_query = NULL
) {
  perform_many_with(
    reqs,
    source,
    max_active,
    progress,
    read_json_body,
    secret_query
  )
}

perform_many_with <- function(
  reqs,
  source,
  max_active,
  progress,
  read_body,
  secret_query = NULL
) {
  out <- vector("list", length(reqs))
  if (length(reqs) == 0) {
    return(out)
  }

  hosts <- vapply(reqs, function(req) url_host(req$url), character(1))

  # The breaker is read once per host rather than once per request, so a batch
  # cannot see a host as both open and closed partway through.
  for (idx in group_by_host(hosts)) {
    host <- hosts[[idx[1]]]
    if (breaker_open(host)) {
      for (i in idx) {
        out[[i]] <- status_skipped(
          source = source,
          detail = paste0(host, " breaker open")
        )
      }
      next
    }
    # on_error = "continue" is what keeps the contract: a transport failure
    # lands in the result list as a condition instead of aborting the batch, and
    # classify_result() already knows how to read that.
    #
    # As in perform_with(), the credential is attached here at dispatch, so the
    # requests these were built from never carried it.
    resps <- httr2::req_perform_parallel(
      lapply(reqs[idx], apply_secret_query, secret_query = secret_query),
      on_error = "continue",
      progress = progress,
      max_active = max_active
    )
    for (k in seq_along(idx)) {
      out[[idx[k]]] <- classify_result(
        resps[[k]],
        source,
        host,
        read_body,
        secret_query
      )
    }
  }
  out
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
  secret_query = NULL
) {
  hits <- lapply(keys, cache_get)
  miss <- which(vapply(hits, is.null, logical(1)))
  if (length(miss) == 0) {
    return(hits)
  }
  fetched <- perform_many_with(
    reqs[miss],
    source,
    max_active,
    progress,
    read_body,
    secret_query
  )
  for (k in seq_along(miss)) {
    res <- fetched[[k]]
    hits[[miss[k]]] <- res
    # Same rule as cached(): only a success is ever stored.
    if (isTRUE(res$ok)) {
      cache()$set(keys[[miss[k]]], res)
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
#' Read the sections on [perform_many()] first. The same two rules apply: pass
#' requests for one host, and supply a `throttle`.
#'
#' @param base_url The service's base URL.
#' @param path A path appended to `base_url`. Length 1 to use the same path for
#'   every request, or one per entry in `queries`.
#' @param queries A list of named lists, one per request. Blank values are
#'   dropped from each.
#' @inheritParams perform_many
#' @param timeout Seconds before a request is abandoned.
#' @param max_tries Total attempts, including the first. Note that httr2 does
#'   not honor this under parallel performance.
#' @param headers A named list of headers, all marked sensitive.
#' @param throttle A throttle spec. See [req_defaults()].
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
  secret_query = NULL
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
    secret_query
  )
}

#' POST many JSON bodies as one batch
#'
#' The batched counterpart to [post_json()], for a JSON or GraphQL endpoint
#' answering many queries. Keyed on the URL and the body together, so two
#' different queries to the same endpoint do not collide.
#'
#' Read the sections on [perform_many()] first.
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
  secret_query = NULL
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
    secret_query
  )
}
