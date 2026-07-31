# Per-host circuit breaker.
#
# httr2 ships its own breaker via req_retry(failure_threshold), but it is
# documented as never firing under req_perform_parallel(), which is exactly how
# a fan-out runs, so this one is explicit.
#
# The rule that matters, and the one the four original copies of this code
# disagreed about: only a TRANSPORT failure counts against a host. Any HTTP
# response at all, even a 500 or a body that will not parse, proves the host is
# reachable and clears the count. Body parsing must never be mistaken for the
# host being down, or one source returning HTML error pages takes itself out of
# rotation for reasons that have nothing to do with reachability.
#
# State is process-global and self-healing: after the cooldown the host is tried
# again with no intervention.

breaker <- new.env(parent = emptyenv())

breaker_threshold <- function() {
  as.integer(env_num("BIOHTTP_BREAKER_THRESHOLD", 3))
}

breaker_cooldown <- function() {
  env_num("BIOHTTP_BREAKER_COOLDOWN", 120)
}

# The host is the breaker key, so one flaky source cannot trip the breaker for
# another. A URL that will not parse falls back to a constant, which is still a
# stable key.
url_host <- function(url) {
  h <- tryCatch(httr2::url_parse(url)$hostname, error = function(e) NULL)
  if (is.null(h) || !nzchar(h)) "unknown-host" else h
}

breaker_state <- function(host) {
  breaker[[host]] %||% list(fails = 0L, tripped_until = 0)
}

#' Is a host's breaker open
#'
#' Open means too many consecutive transport failures and still inside the
#' cooldown. While open, [perform()] short-circuits to a `skipped` envelope
#' instead of waiting on a request that is likely to fail anyway.
#'
#' @param host A hostname, as returned by parsing a request URL.
#' @param now The current time in seconds since the epoch. Exposed so a test can
#'   drive the clock rather than sleep.
#'
#' @return A single logical.
#'
#' @examples
#' breaker_reset()
#' breaker_open("gnomad.broadinstitute.org")
#'
#' @export
breaker_open <- function(host, now = as.numeric(Sys.time())) {
  isTRUE(breaker_state(host)$tripped_until > now)
}

#' Record a call outcome against a host
#'
#' `reachable` means an HTTP response came back at all, whatever its status. A
#' reachable call clears the count; the Kth consecutive unreachable one trips
#' the breaker for the cooldown window.
#'
#' Pass `reachable = TRUE` for any response in hand, including a 5xx and
#' including a 2xx whose body will not parse. Only a genuine transport failure
#' is `FALSE`.
#'
#' @param host A hostname.
#' @param reachable Whether an HTTP response arrived.
#' @param now The current time in seconds since the epoch.
#'
#' @return The host's new breaker state, invisibly.
#'
#' @examples
#' breaker_reset()
#' breaker_record("example.org", reachable = FALSE)
#' breaker_record("example.org", reachable = TRUE)
#' breaker_open("example.org")
#'
#' @export
breaker_record <- function(host, reachable, now = as.numeric(Sys.time())) {
  if (isTRUE(reachable)) {
    breaker[[host]] <- list(fails = 0L, tripped_until = 0)
  } else {
    st <- breaker_state(host)
    fails <- st$fails + 1L
    tripped_until <- if (fails >= breaker_threshold()) {
      now + breaker_cooldown()
    } else {
      st$tripped_until
    }
    breaker[[host]] <- list(fails = fails, tripped_until = tripped_until)
  }
  invisible(breaker[[host]])
}

#' Clear all breaker state
#'
#' Forgets every host's failure count and cooldown. For tests, and for a manual
#' "try again" once a source is known to be back.
#'
#' @return `NULL`, invisibly.
#'
#' @examples
#' breaker_reset()
#'
#' @export
breaker_reset <- function() {
  rm(list = ls(breaker), envir = breaker)
  invisible(NULL)
}
