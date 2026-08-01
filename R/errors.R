# Failure messages.
#
# The wording lives here rather than at each call site so every consumer says
# the same thing about the same failure. `error` is the sentence a user reads;
# `detail` is what a log records. Keeping them apart is what lets an app render
# a clean failure card without leaking a stack trace into it.

#' A user-facing sentence for a failed call
#'
#' One actionable sentence per failure class, with no httr2 or curl internals in
#' it. Pass `http` for a response that arrived, or `condition` for a transport
#' failure where none did.
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
  if (!is.na(http)) {
    if (http == 404) {
      return(paste0("No ", source, " data was found for this query."))
    }
    if (http == 429) {
      return(paste0(
        source,
        " is busy right now. Please try again in a moment."
      ))
    }
    if (http >= 500) {
      return(paste0(source, " is temporarily unavailable. Please try again."))
    }
    return(paste0("Could not retrieve data from ", source, " right now."))
  }
  raw <- tolower(if (is.null(condition)) "" else conditionMessage(condition))
  if (grepl("timeout|timed out", raw)) {
    return(paste0(source, " took too long to respond. Please try again."))
  }
  if (
    grepl("resolve|name or service|dns|offline|could not connect|refused", raw)
  ) {
    return(paste0("Could not reach ", source, ". Check your connection."))
  }
  paste0(source, " is temporarily unavailable. Please try again shortly.")
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
