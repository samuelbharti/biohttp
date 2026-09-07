# Per-host transport dispatch counters.
#
# The batched retry path in parallel.R can now send several passes for the
# same original request list, and a caller running a large fan-out (hundreds
# of chunks against one host) has no other way to see how many requests that
# actually became, or whether a rate limiter engaged, without instrumenting
# the call site itself. This is diagnostic only: nothing in the package reads
# it back to make a decision, so it is safe to poll after a run, or reset
# before one to isolate a single call's counts.

transport_stats_env <- new.env(parent = emptyenv())

transport_stats_record <- function(
  host,
  dispatched = 0L,
  retried = 0L,
  rate_limited = 0L
) {
  cur <- transport_stats_env[[host]] %||%
    list(dispatched = 0L, retried = 0L, rate_limited = 0L)
  transport_stats_env[[host]] <- list(
    dispatched = cur$dispatched + dispatched,
    retried = cur$retried + retried,
    rate_limited = cur$rate_limited + rate_limited
  )
  invisible(transport_stats_env[[host]])
}

#' How many requests went out, per host
#'
#' How many requests the batched path (see [perform_many()] and its
#' cached counterparts) actually sent, how many of those were a retry pass
#' rather than the first attempt, and how many came back rate limited,
#' since the process started or the last [transport_stats_reset()].
#'
#' @return A data frame with one row per host: `host`, `dispatched`,
#'   `retried`, `rate_limited`. Zero rows when nothing has dispatched yet.
#'
#' @examples
#' transport_stats_reset()
#' transport_stats()
#'
#' @export
transport_stats <- function() {
  hosts <- ls(transport_stats_env)
  if (length(hosts) == 0) {
    return(data.frame(
      host = character(),
      dispatched = integer(),
      retried = integer(),
      rate_limited = integer(),
      stringsAsFactors = FALSE
    ))
  }
  rows <- lapply(hosts, function(h) {
    s <- transport_stats_env[[h]]
    data.frame(
      host = h,
      dispatched = s$dispatched,
      retried = s$retried,
      rate_limited = s$rate_limited,
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

#' Clear the request counts
#'
#' @return `NULL`, invisibly.
#'
#' @examples
#' transport_stats_reset()
#'
#' @export
transport_stats_reset <- function() {
  rm(list = ls(transport_stats_env), envir = transport_stats_env)
  invisible(NULL)
}
