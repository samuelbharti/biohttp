# Per-host rate-limit ledger, separate from the circuit breaker.
#
# A 429 means "you asked too fast", not "the host is down". breaker.R already
# treats any HTTP response as reachable on purpose, so a 429 must never trip
# the breaker; that rule is correct and stays. But nothing paced the NEXT
# request either, so a rate-limited host got hit again at the same rate that
# just triggered the limit. This is the other half: a process-global pause
# per host, set from a 429 or 503's Retry-After (or a fallback when there is
# none) and honored before the next dispatch to that host.
#
# State is process-global, like the breaker, and self-expiring: once `now`
# passes `pause_until` the host is simply not paused, with no reset needed.

ratelimit <- new.env(parent = emptyenv())

ratelimit_default_pause <- function() {
  env_num("BIOHTTP_RATELIMIT_DEFAULT_PAUSE", 5)
}

#' Record a pause for a host
#'
#' Sets how long the next dispatch to `host` should wait: from a 429 or
#' 503's `Retry-After` when one was sent, or a default pause (5 seconds,
#' `BIOHTTP_RATELIMIT_DEFAULT_PAUSE` to override) otherwise. A call only
#' extends an existing pause, never shortens one, so of several retryable
#' responses recorded from one batch, the longest asked-for wait wins.
#'
#' @param host A hostname, as returned by parsing a request URL.
#' @param retry_after Seconds to wait, usually from
#'   [httr2::resp_retry_after()]. `NULL` or `NA` falls back to the default
#'   pause.
#' @param now The current time in seconds since the epoch. Exposed so a test
#'   can drive the clock rather than sleep.
#'
#' @return The host's new `pause_until`, invisibly.
#'
#' @examples
#' ratelimit_reset()
#' ratelimit_record("rest.ensembl.org", retry_after = 5)
#' ratelimit_reset()
#'
#' @export
ratelimit_record <- function(
  host,
  retry_after = NULL,
  now = as.numeric(Sys.time())
) {
  pause <- if (is.null(retry_after) || is.na(retry_after) || retry_after <= 0) {
    ratelimit_default_pause()
  } else {
    retry_after
  }
  until <- now + pause
  existing <- ratelimit[[host]] %||% -Inf
  ratelimit[[host]] <- max(existing, until)
  invisible(ratelimit[[host]])
}

#' Wait out a host's recorded pause
#'
#' A no-op when the host has no pause recorded, or the recorded one has
#' already elapsed. `sleep` is injectable so a test can assert the duration
#' asked for without actually waiting for it.
#'
#' @param host A hostname.
#' @param now The current time in seconds since the epoch.
#' @param sleep The sleep function to call with the remaining seconds.
#'   Defaults to [Sys.sleep()].
#'
#' @return The number of seconds waited (`0` when there was nothing to wait
#'   for), invisibly.
#'
#' @examples
#' ratelimit_reset()
#' ratelimit_wait("rest.ensembl.org")
#'
#' @export
ratelimit_wait <- function(
  host,
  now = as.numeric(Sys.time()),
  sleep = Sys.sleep
) {
  until <- ratelimit[[host]] %||% -Inf
  remaining <- until - now
  if (remaining > 0) {
    sleep(remaining)
  }
  invisible(max(remaining, 0))
}

#' Clear all recorded pauses
#'
#' For tests, and for a manual "try again now" once a source's limiter is
#' known to have reset.
#'
#' @return `NULL`, invisibly.
#'
#' @examples
#' ratelimit_reset()
#'
#' @export
ratelimit_reset <- function() {
  rm(list = ls(ratelimit), envir = ratelimit)
  invisible(NULL)
}
