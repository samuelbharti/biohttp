#' @keywords internal
#'
#' @details
#' Start at [get_json()], [post_json()], or [get_text()] for a call that
#' assembles, performs, and caches itself. Drop to [perform()] when you need to
#' build the request yourself, and pass it through [req_defaults()] first.
#'
#' Every one of them returns an [envelope()] rather than raising, so a client
#' branches on `res$status` and writes no `tryCatch()` of its own.
#'
#' @section On the jsonlite import:
#' `jsonlite` is imported but never called here, because httr2 calls it on this
#' package's behalf: `httr2::resp_body_json()` does
#' `check_installed("jsonlite")` at runtime, and httr2 keeps it in Suggests
#' rather than Imports. Declaring it is what stops `get_json()` failing on a
#' clean install. The import below is what makes that declaration honest to
#' `R CMD check`.
#'
#' @importFrom jsonlite fromJSON
"_PACKAGE"
