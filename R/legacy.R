# The migration shim.
#
# Deprecated from birth, on purpose. It exists so `variant-reviewer` and
# `genescout` can adopt biohttp without rewriting every call site in the same
# pull request, and for no other reason. Nothing new should call it.

deprecation_warned <- new.env(parent = emptyenv())

# Warn once per session rather than on every call. A migration runs this in a
# loop, and a warning per request would bury the signal it is meant to send.
warn_once <- function(id, message) {
  if (isTRUE(deprecation_warned[[id]])) {
    return(invisible(FALSE))
  }
  deprecation_warned[[id]] <- TRUE
  warning(message, call. = FALSE)
  invisible(TRUE)
}

#' Convert an envelope to the old four-field shape
#'
#' @description
#' **Deprecated.** Scheduled for removal in 0.1.0's successor line, 0.3.0.
#'
#' Translates an [envelope()] into the shape `variant-reviewer` and `genescout`
#' return today:
#'
#' ```r
#' list(ok = TRUE, status = 200L, data = <parsed>, error = NULL)
#' ```
#'
#' `detail` is carried through as a fifth field, because `variant-reviewer`'s
#' call sites log it and dropping it would break them.
#'
#' @section Why this is deprecated on arrival:
#' The old shape cannot express two things the new one can. It has no way to say
#' "skipped because the host's breaker was open" as distinct from "failed", and
#' it collapses the user-facing sentence and the log detail into one field. Both
#' are load-bearing, and neither can be reconstructed once a call site is
#' written against the old shape.
#'
#' Note the collision in the word `status`: here it is the HTTP code, an
#' integer, and in an [envelope()] it is the enum. That is exactly the ambiguity
#' the new contract removes.
#'
#' @section Removal:
#' Scheduled for removal in 0.3.0. Use it to land a migration with a reviewable
#' diff, then delete the call sites and delete this.
#'
#' Warns once per session, not once per call, so a migration loop stays
#' readable.
#'
#' @param res An envelope from [perform()] or one of the convenience wrappers.
#'
#' @return A list with `ok`, `status` (the HTTP code), `data`, `error`, and
#'   `detail`.
#'
#' @examples
#' old <- as_legacy_envelope(status_ok(data = list(n = 1), source = "MyGene"))
#' old$ok
#' old$status
#'
#' @export
as_legacy_envelope <- function(res) {
  warn_once(
    "as_legacy_envelope",
    paste0(
      "as_legacy_envelope() is deprecated and will be removed in biohttp ",
      "0.3.0. Branch on res$status instead; see vignette(\"biohttp\")."
    )
  )
  list(
    ok = isTRUE(res$ok),
    status = res$http,
    data = res$data,
    error = res$error,
    detail = res$detail
  )
}
