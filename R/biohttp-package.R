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
#' @importFrom jsonlite fromJSON
"_PACKAGE"

# On the jsonlite import above. We import jsonlite but never call it here.
# httr2 calls it for us: resp_body_json() does check_installed("jsonlite") at
# run time, and httr2 keeps jsonlite in Suggests rather than Imports. Declaring
# it is what stops get_json() failing on a clean install, and the importFrom is
# what makes that declaration honest to R CMD check. This is a packaging
# detail, so it lives here rather than on the help page.
