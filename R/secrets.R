# Query-string credentials.
#
# Some services take their credential in the query string rather than in a
# header. NCBI E-utilities is the one that forced this: its `api_key` raises the
# rate limit from 3 to 10 requests a second, and there is no header form.
#
# A secret in the query string is a different problem from a secret in a header,
# in three ways, and all three are handled here.
#
#   1. It would land in the cache key, because the key is built from the URL.
#      Adding or rotating a key would then silently invalidate every entry the
#      process had already cached.
#   2. It would print. `print(req)`, an inspected request, or a traceback all
#      show `req$url` verbatim.
#   3. It would reach an error message. A transport failure carries the curl
#      message, which usually contains the URL that failed.
#
# The fix for the first two is to keep the secret out of the request object
# entirely and append it only at dispatch, inside perform_with(). The request a
# caller holds, and the URL the cache key is built from, never contain it. The
# fix for the third is redact_secrets(), applied to every message built from a
# condition.
#
# WHEN NOT TO USE THIS.
#
# `secret_query` is for a credential that changes the rate limit or the quota,
# not the response. Because it is deliberately excluded from the cache key, two
# calls that differ only in their key are treated as the same call. A credential
# that changes what comes back must go in `headers`, which is part of the key.

# Append the secret parameters to a request, immediately before it is sent.
apply_secret_query <- function(req, secret_query) {
  if (is.null(secret_query) || length(secret_query) == 0) {
    return(req)
  }
  secret_query <- secret_query[!vapply(secret_query, is_blank, logical(1))]
  if (length(secret_query) == 0) {
    return(req)
  }
  do.call(httr2::req_url_query, c(list(req), secret_query))
}

#' Remove secret values from a string
#'
#' Replaces the literal value of each secret wherever it appears. Used on the
#' messages built from a transport failure, because a curl error normally
#' carries the URL that failed and that URL may hold a query-string credential.
#'
#' Matching on the value rather than on the parameter name is deliberate: the
#' same secret can reach a message through a URL, a header dump, or a proxy
#' error, and only the value is common to all three.
#'
#' @param text A single string.
#' @param secrets A named list of secret values, as passed to `secret_query`.
#'
#' @return `text`, with every secret value replaced by `<redacted>`.
#'
#' @examples
#' redact_secrets(
#'   "Could not resolve host: example.org/?api_key=abc123",
#'   list(api_key = "abc123")
#' )
#'
#' @export
redact_secrets <- function(text, secrets = NULL) {
  if (is.null(secrets) || length(secrets) == 0) {
    return(text)
  }
  if (length(text) != 1 || is.na(text) || !nzchar(text)) {
    return(text)
  }
  for (value in secrets) {
    value <- as.character(value)
    # A one-character or empty secret would turn the message into noise, and is
    # not a credential worth protecting anyway.
    if (length(value) == 1 && !is.na(value) && nchar(value) > 1) {
      text <- gsub(value, "<redacted>", text, fixed = TRUE)
    }
  }
  text
}
