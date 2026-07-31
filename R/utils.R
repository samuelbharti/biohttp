# Micro-utilities.
#
# pluck_at() and is_blank() are duplicated in shinykit on purpose. The
# alternative was for biohttp to depend on shinykit, which would drag shiny into
# a package whose whole point is being Shiny-free. Three lines each is a cheaper
# price than that dependency, so do not "fix" this by adding one.

`%||%` <- function(x, y) if (is.null(x)) y else x # nolint: object_name_linter.

#' Is a value blank
#'
#' TRUE for `NULL`, a zero-length value, `NA`, or a string that is empty once
#' trimmed. Used to drop empty query parameters so a request never sends
#' `param=` with nothing after it.
#'
#' @param x Any value.
#'
#' @return A single logical.
#'
#' @examples
#' is_blank(NULL)
#' is_blank("  ")
#' is_blank("gnomAD")
#'
#' @export
is_blank <- function(x) {
  is.null(x) ||
    length(x) == 0 ||
    (length(x) == 1 && (is.na(x) || identical(trimws(as.character(x)), "")))
}

#' Pull a value out of a nested list
#'
#' Walks a key path and returns `default` if any level is missing or `NULL`,
#' rather than erroring. Parsed JSON is deeply nested and frequently missing
#' branches, so this is the difference between a client that reads cleanly and
#' one buried in `if (!is.null(...))`.
#'
#' @param x A list, usually a parsed JSON body.
#' @param ... Keys to follow, outermost first.
#' @param default Returned when any level of the path is missing or `NULL`.
#'
#' @return The value at the end of the path, or `default`.
#'
#' @examples
#' body <- list(data = list(gene = list(symbol = "BRCA1")))
#' pluck_at(body, "data", "gene", "symbol")
#' pluck_at(body, "data", "variant", "id", default = NA_character_)
#'
#' @export
pluck_at <- function(x, ..., default = NULL) {
  keys <- c(...)
  for (key in keys) {
    if (is.null(x) || !is.list(x) || is.null(x[[key]])) {
      return(default)
    }
    x <- x[[key]]
  }
  if (is.null(x)) default else x
}

# A positive number from an environment variable, else the default. A blank or
# malformed setting falls back rather than silently disabling a timeout or a
# cache, which is the failure mode that is hardest to notice.
env_num <- function(name, default) {
  raw <- Sys.getenv(name, unset = "")
  if (!nzchar(raw)) {
    return(default)
  }
  val <- suppressWarnings(as.numeric(raw))
  if (length(val) != 1L || is.na(val) || val <= 0) default else val
}

# A logical from an environment variable. Anything not clearly true is false, so
# an opt-in stays off unless it was asked for unambiguously.
env_flag <- function(name, default = FALSE) {
  raw <- trimws(tolower(Sys.getenv(name, unset = "")))
  if (!nzchar(raw)) {
    return(default)
  }
  raw %in% c("1", "true", "yes", "on")
}
