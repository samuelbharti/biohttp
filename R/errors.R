# Failure messages.
#
# The wording lives here rather than at each call site so every consumer says
# the same thing about the same failure. `error` is the sentence a user reads;
# `detail` is what a log records. Keeping them apart is what lets an app render
# a clean failure card without leaking a stack trace into it.
#
# Every user-facing sentence in the package comes from status_message(). It used
# to be two sets, one here and one hardcoded in the status_*() constructors, and
# they had already drifted: three different sentences existed for "temporarily
# unavailable", differing only in whether they ended "Please try again." or
# "Please try again shortly." or nothing at all. That is the same
# copy-then-diverge this package was extracted to stop, so there is one set now.

# The built-in wording. Separate from status_message() so an override that
# returns something unusable has something to fall back to.
default_status_message <- function(source, status, http, condition) {
  if (identical(status, "no_data")) {
    return(paste0("No ", source, " data was found for this query."))
  }
  if (identical(status, "rate_limited")) {
    return(paste0(source, " is busy right now. Please try again in a moment."))
  }
  if (identical(status, "timeout")) {
    return(paste0(source, " took too long to respond. Please try again."))
  }
  if (identical(status, "skipped")) {
    return(paste0(source, " was skipped (host temporarily unreachable)."))
  }
  if (identical(status, "ok") || identical(status, "stale")) {
    return(NULL)
  }
  # Everything left is `error`, which splits on what we know about the failure.
  # A response that arrived reads differently from one that never did.
  if (!is.na(http)) {
    if (http >= 500) {
      return(paste0(source, " is temporarily unavailable. Please try again."))
    }
    return(paste0("Could not retrieve data from ", source, " right now."))
  }
  raw <- tolower(if (is.null(condition)) "" else conditionMessage(condition))
  if (
    grepl("resolve|name or service|dns|offline|could not connect|refused", raw)
  ) {
    return(paste0("Could not reach ", source, ". Check your connection."))
  }
  paste0(source, " is temporarily unavailable. Please try again.")
}

#' The user-facing sentence for an outcome
#'
#' Every `error` field in the package is produced here, so the seven statuses
#' cannot drift apart and an application can replace all of them at once.
#'
#' @section Supplying your own wording:
#' Set `biohttp.status_message` to a function of `source`, `status`, `http` and
#' `condition`. It is called instead of the built-in, and it is the way to keep
#' an app's own voice, or to localise, while adopting the transport:
#'
#' ```r
#' options(biohttp.status_message = function(source, status, http, condition) {
#'   if (identical(status, "timeout")) {
#'     paste0(source, " took too long. Please try again shortly.")
#'   } else {
#'     NULL  # fall through to the built-in for everything else
#'   }
#' })
#' ```
#'
#' Returning anything other than a single non-empty string falls back to the
#' built-in, so covering one case and leaving the rest is expected rather than
#' an error.
#'
#' **An override cannot break the return-a-value contract.** It runs inside a
#' `tryCatch()`, and a function that raises is treated as though it returned
#' nothing. This matters because the override runs on the failure path, which is
#' precisely where the package promises never to raise.
#'
#' @param source A friendly label for the service, for example `"gnomAD"`.
#' @param status One of [STATUS_LEVELS].
#' @param http An HTTP status code, or `NA_integer_` when no response arrived.
#' @param condition A caught condition, used when no response arrived.
#'
#' @return A single string, or `NULL` for a status that carries no message.
#'
#' @examples
#' status_message("gnomAD", "no_data")
#' status_message("gnomAD", "error", http = 503L)
#'
#' withr::with_options(
#'   list(biohttp.status_message = function(source, status, http, condition) {
#'     paste0(source, " says: ", status)
#'   }),
#'   status_message("gnomAD", "timeout")
#' )
#'
#' @export
status_message <- function(
  source = "API",
  status = "error",
  http = NA_integer_,
  condition = NULL
) {
  override <- getOption("biohttp.status_message")
  if (is.function(override)) {
    msg <- tryCatch(
      override(
        source = source,
        status = status,
        http = http,
        condition = condition
      ),
      error = function(e) NULL
    )
    if (is.character(msg) && length(msg) == 1L && !is.na(msg) && nzchar(msg)) {
      return(msg)
    }
  }
  default_status_message(source, status, http, condition)
}

#' A user-facing sentence for a failed call
#'
#' Works out which status the failure is and asks [status_message()] for the
#' wording, so it honours `biohttp.status_message` like everything else. Pass
#' `http` for a response that arrived, or `condition` for a transport failure
#' where none did.
#'
#' @param source A friendly label for the service, for example `"gnomAD"`.
#' @param http An HTTP status code, or `NA_integer_` when no response arrived.
#' @param condition A caught condition, used only when `http` is `NA`.
#'
#' @return A single string.
#'
#' @examples
#' http_error_message("gnomAD", http = 404L)
#' http_error_message("gnomAD", http = 503L)
#' http_error_message("gnomAD", condition = simpleError("Timeout was reached"))
#'
#' @export
http_error_message <- function(
  source,
  http = NA_integer_,
  condition = NULL
) {
  status <- if (!is.na(http)) {
    classify_http(http)
  } else if (is.null(condition)) {
    "error"
  } else {
    classify_condition(condition)
  }
  status_message(
    source = source,
    status = status,
    http = http,
    condition = condition
  )
}

#' Catch a GraphQL query error inside a 200
#'
#' GraphQL reports query errors in the body of an HTTP 200, as a top-level
#' `errors` array, so a 2xx status is not enough to call a call successful.
#'
#' Returns an error envelope for either kind of failure, transport or query, so
#' a GraphQL client collapses the two checks into one:
#'
#' ```r
#' res <- post_json(url, body, source = "gnomAD")
#' bad <- graphql_error(res, "gnomAD")
#' if (!is.null(bad)) return(bad)
#' ```
#'
#' @param res An envelope from [post_json()] or [perform()].
#' @param source A friendly label for the service.
#'
#' @return The failing envelope, or `NULL` when the call genuinely succeeded.
#'
#' @examples
#' clean <- status_ok(data = list(data = list(gene = "BRCA1")), source = "G")
#' graphql_error(clean, "G")
#'
#' queried <- status_ok(data = list(errors = list(list(message = "bad"))))
#' graphql_error(queried, "G")$status
#'
#' @export
graphql_error <- function(res, source = "API") {
  if (!isTRUE(res$ok)) {
    return(res)
  }
  if (!is.null(res$data$errors)) {
    return(status_error(
      source = source,
      http = res$http,
      error = paste0(source, " returned a query error."),
      detail = "graphql errors array present"
    ))
  }
  NULL
}
