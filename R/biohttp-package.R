#' @keywords internal
#'
#' @details
#' The transport itself lands in Phase 1. Until then the imports below exist
#' only to hold the `Imports` declaration in `DESCRIPTION`, so that the
#' dependency contract is fixed before any code depends on it. They are
#' replaced by real usage as `perform()`, the breaker, and the cache arrive.
#'
#' @importFrom cachem cache_mem
#' @importFrom httr2 request
#' @importFrom rlang abort
"_PACKAGE"
