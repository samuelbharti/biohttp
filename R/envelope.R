# The result envelope.
#
# Every call returns one of these. Nothing in this package raises a condition on
# an HTTP or a parse failure, so a caller branches on a value and never writes
# its own tryCatch().
#
# Partial failure is the normal case for the clients this serves: many public
# sources times many queries means some cells resolve, some time out, some are
# skipped because a host is down, and some genuinely have no data. A two-value
# ok/error contract cannot express that, which is why the status is an enum.

#' The seven envelope statuses
#'
#' Ordered from best outcome to worst.
#'
#' \describe{
#'   \item{`ok`}{The call succeeded and `data` holds the parsed result.}
#'   \item{`no_data`}{The source was reached and has nothing for this query, for
#'     example a 404 or an empty body. This is an answer, not a fault.}
#'   \item{`stale`}{A cached value served past its freshness window.}
#'   \item{`rate_limited`}{The source asked the caller to slow down, a 429.}
#'   \item{`timeout`}{The request did not return in time.}
#'   \item{`skipped`}{Not attempted, because the host's breaker is open or a
#'     caller-side budget was hit.}
#'   \item{`error`}{Anything else: a 5xx, a malformed body, a transport
#'     failure.}
#' }
#'
#' @format A character vector of length seven.
#'
#' @docType data
#' @keywords datasets
#'
#' @export
STATUS_LEVELS <- c(
  "ok",
  "no_data",
  "stale",
  "rate_limited",
  "timeout",
  "skipped",
  "error"
)

#' Build a result envelope
#'
#' The single return shape for the whole package. `ok` is derived from `status`
#' rather than passed in, so the two can never disagree.
#'
#' A client that only wants the parsed body can use [body_or_null()] instead of
#' reading the fields directly.
#'
#' @param status One of [STATUS_LEVELS].
#' @param data The parsed body on success, `NULL` otherwise.
#' @param source A friendly label for the service, used in the user-facing
#'   message. For example `"gnomAD"`.
#' @param http The HTTP status code, or `NA_integer_` when no response arrived.
#' @param error One sentence fit to show a user. Never carries technical
#'   detail.
#' @param detail The technical cause, for a log. Never shown to a user.
#' @param retry_after Seconds a `Retry-After` header asked the caller to
#'   wait, or `NA_real_` when the response carried none. Diagnostic: nothing
#'   in this package reads it back except the batched retry path in
#'   `parallel.R`, which shares this same field.
#'
#' @return A list with `ok`, `status`, `http`, `data`, `source`, `error`,
#'   `detail`, `retry_after`, and `ts`.
#'
#' @examples
#' envelope("ok", data = list(symbol = "BRCA1"), source = "MyGene", http = 200L)
#' envelope("error", source = "gnomAD", http = 503L)
#'
#' @export
envelope <- function(
  status,
  data = NULL,
  source = "API",
  http = NA_integer_,
  error = NULL,
  detail = NULL,
  retry_after = NA_real_
) {
  # Exact matching, not match.arg(). match.arg() partial-matches, so a typo like
  # envelope("t") silently becomes a timeout envelope and envelope("sk") a
  # skipped one. A status is a contract, not a convenience argument.
  if (
    length(status) != 1L ||
      !is.character(status) ||
      !(status %in% STATUS_LEVELS)
  ) {
    stop(
      "`status` must be one of: ",
      paste(STATUS_LEVELS, collapse = ", "),
      call. = FALSE
    )
  }
  list(
    ok = identical(status, "ok"),
    status = status,
    http = as.integer(http),
    data = data,
    source = source,
    error = error,
    detail = detail,
    retry_after = as.numeric(retry_after),
    ts = Sys.time()
  )
}

#' Envelope constructors, one per status
#'
#' Shorthands for [envelope()] that fill in the user-facing `error` sentence for
#' their status. `error` is what a user reads; `detail` is what a log records.
#'
#' The sentence comes from [status_message()], so setting
#' `biohttp.status_message` changes what these produce too.
#'
#' @inheritParams envelope
#'
#' @return An envelope list, as described in [envelope()].
#'
#' @examples
#' status_ok(data = list(n = 1), source = "MyGene")
#' status_no_data(source = "gnomAD", http = 404L)
#' status_skipped(source = "gnomAD", detail = "gnomad.broadinstitute.org open")
#'
#' @name status_constructors
NULL

#' @rdname status_constructors
#' @export
status_ok <- function(data, source = "API", http = 200L) {
  envelope("ok", data = data, source = source, http = http)
}

#' @rdname status_constructors
#' @export
status_no_data <- function(source = "API", http = NA_integer_, detail = NULL) {
  envelope(
    "no_data",
    source = source,
    http = http,
    error = status_message(source, "no_data", http = http),
    detail = detail
  )
}

#' @rdname status_constructors
#' @export
status_stale <- function(data, source = "API", detail = NULL) {
  envelope("stale", data = data, source = source, detail = detail)
}

#' @rdname status_constructors
#' @export
status_rate_limited <- function(
  source = "API",
  http = 429L,
  detail = NULL,
  retry_after = NA_real_
) {
  envelope(
    "rate_limited",
    source = source,
    http = http,
    error = status_message(source, "rate_limited", http = http),
    detail = detail,
    retry_after = retry_after
  )
}

#' @rdname status_constructors
#' @export
status_timeout <- function(source = "API", detail = NULL) {
  envelope(
    "timeout",
    source = source,
    error = status_message(source, "timeout"),
    detail = detail
  )
}

#' @rdname status_constructors
#' @export
status_skipped <- function(source = "API", detail = NULL) {
  envelope(
    "skipped",
    source = source,
    error = status_message(source, "skipped"),
    detail = detail
  )
}

#' @rdname status_constructors
#' @export
status_error <- function(
  source = "API",
  http = NA_integer_,
  error = NULL,
  detail = NULL
) {
  envelope(
    "error",
    source = source,
    http = http,
    error = error %||% status_message(source, "error", http = http),
    detail = detail
  )
}

#' The parsed body, or NULL
#'
#' For a client that wants the body and does not care why a call failed. Every
#' other field is still there for a client that does care, so reach for this
#' when the failure is genuinely not actionable, not to avoid reading the
#' envelope.
#'
#' Returns the body for `ok` **and for `stale`**. A stale envelope carries real
#' data that is merely past its freshness window, so returning `NULL` for it
#' would throw away the one thing the caller asked for. Branch on `res$status`
#' if the difference matters. Note that `res$ok` is `FALSE` for `stale`, which
#' is what keeps [cached()] from storing it.
#'
#' @param res An envelope from [perform()] or one of the convenience wrappers.
#'
#' @return `res$data` when the status is `ok` or `stale`, otherwise `NULL`.
#'
#' @examples
#' body_or_null(status_ok(data = list(n = 1)))
#' body_or_null(status_stale(data = list(n = 1)))
#' body_or_null(status_error(source = "gnomAD"))
#'
#' @export
body_or_null <- function(res) {
  if (isTRUE(res$status %in% c("ok", "stale"))) res$data else NULL
}

#' Classify an HTTP status code onto the status enum
#'
#' Only the codes the transport treats as an outcome in themselves are
#' classified. A 2xx is the caller's to interpret, since a 200 carrying an empty
#' result may still be `no_data` once parsed.
#'
#' @param http An HTTP status code.
#'
#' @return One of [STATUS_LEVELS].
#'
#' @examples
#' classify_http(404L)
#' classify_http(429L)
#' classify_http(503L)
#'
#' @export
classify_http <- function(http) {
  http <- suppressWarnings(as.integer(http))
  if (length(http) != 1 || is.na(http)) {
    return("error")
  }
  if (http >= 200 && http < 300) {
    return("ok")
  }
  if (http == 404) {
    return("no_data")
  }
  if (http == 408) {
    return("timeout")
  }
  if (http == 429) {
    return("rate_limited")
  }
  "error"
}

#' Classify a transport condition onto the status enum
#'
#' For a failure with no HTTP response at all. A DNS failure or a refused
#' connection is an `error`; only an actual timeout is a `timeout`, because the
#' two read very differently to a user deciding whether to retry.
#'
#' @param cond A condition caught from a failed request.
#'
#' @return One of [STATUS_LEVELS].
#'
#' @examples
#' classify_condition(simpleError("Timeout was reached"))
#' classify_condition(simpleError("Could not resolve host"))
#'
#' @export
classify_condition <- function(cond) {
  msg <- tolower(paste(conditionMessage(cond), collapse = " "))
  if (grepl("timeout|timed out", msg)) {
    return("timeout")
  }
  "error"
}
