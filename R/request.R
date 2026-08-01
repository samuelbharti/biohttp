# Request defaults.
#
# Everything a request needs before it goes out, in one place, so a client
# author gets the policy for free rather than remembering it.

#' Build an attributable User-Agent string
#'
#' Public sources ask callers to identify themselves. A caller identity plus a
#' contact route let a source operator reach you before they rate-limit you.
#'
#' The package deliberately does not ship an identity of its own. A consumer
#' passes its own, or sets `BIOHTTP_CALLER_IDENTITY`, `BIOHTTP_CONTACT_URL`, and
#' `BIOHTTP_CONTACT_EMAIL` so a hosted deployment can set them without touching
#' code.
#'
#' @param identity The calling application's name. Defaults to
#'   `BIOHTTP_CALLER_IDENTITY`, then to `"biohttp"`.
#' @param version The calling application's version.
#' @param url A URL an operator can look up, usually the app's repository.
#'   Defaults to `BIOHTTP_CONTACT_URL`.
#' @param email A contact address. Defaults to `BIOHTTP_CONTACT_EMAIL`. Left out
#'   of the string entirely when blank, rather than printed empty.
#'
#' @return A single string.
#'
#' @examples
#' user_agent("my-shiny-app", "1.2.0", email = "ops@example.org")
#' user_agent("my-client-package", "0.4.0")
#'
#' @export
user_agent <- function(
  identity = Sys.getenv("BIOHTTP_CALLER_IDENTITY", "biohttp"),
  version = as.character(getNamespaceVersion("biohttp")),
  url = Sys.getenv("BIOHTTP_CONTACT_URL", ""),
  email = Sys.getenv("BIOHTTP_CONTACT_EMAIL", "")
) {
  parts <- c(
    if (nzchar(url)) paste0("+", url),
    if (nzchar(email)) paste0("mailto:", email)
  )
  if (length(parts) == 0) {
    return(sprintf("%s/%s", identity, version))
  }
  sprintf("%s/%s (%s)", identity, version, paste(parts, collapse = "; "))
}

# Indirection so req_defaults() can default its `user_agent` argument without
# the argument name shadowing the function of the same name.
default_user_agent <- function() {
  user_agent()
}

#' Is a response worth retrying
#'
#' A 429 and the standard 5xx codes are transient. Everything else is a settled
#' answer, and retrying it just spends someone else's capacity.
#'
#' @param resp An httr2 response.
#'
#' @return A single logical.
#'
#' @examples
#' is_transient(httr2::response(status_code = 503))
#' is_transient(httr2::response(status_code = 404))
#'
#' @export
is_transient <- function(resp) {
  httr2::resp_status(resp) %in% c(429L, 500L, 502L, 503L, 504L)
}

#' Apply the shared request options
#'
#' Timeout, bounded retry on transient failures, an attributable user agent, and
#' optionally a throttle and headers.
#'
#' `req_error()` is disarmed here on purpose. httr2 would otherwise raise on a
#' non-2xx, and this package normalizes every outcome into an envelope instead,
#' so [perform()] needs the response object rather than a condition.
#'
#' Headers are attached with `.redact` set to their names, so a token never
#' prints in an inspected request, a log line, or an error message. Header auth
#' also keeps the secret out of the URL, where it would end up in access logs.
#'
#' @param req An httr2 request.
#' @param timeout Seconds before the request is abandoned.
#' @param max_tries Total attempts, including the first.
#' @param headers A named list of headers. All of them are marked sensitive.
#' @param throttle An optional list with `capacity`, `fill_time_s`, and `realm`.
#'   httr2 token buckets are per process, so a realm keyed on the host gives one
#'   honest bucket per host. Defaults to the request's own host.
#' @param user_agent The User-Agent string. See [user_agent()].
#'
#' @return The request, with the options applied.
#'
#' @examples
#' req_defaults(httr2::request("https://example.org"), timeout = 5)
#'
#' # A key-gated source. The token is redacted from anything printable.
#' req_defaults(
#'   httr2::request("https://example.org"),
#'   headers = list(Authorization = "Bearer secret-token")
#' )
#'
#' @export
req_defaults <- function(
  req,
  timeout = 20,
  max_tries = 3,
  headers = NULL,
  throttle = NULL,
  user_agent = default_user_agent()
) {
  req <- httr2::req_timeout(req, timeout)
  req <- httr2::req_retry(
    req,
    max_tries = max_tries,
    is_transient = is_transient
  )
  # Do not let httr2 raise on an HTTP error; perform() normalizes it instead.
  req <- httr2::req_error(req, is_error = function(resp) FALSE)
  req <- httr2::req_user_agent(req, user_agent)
  if (!is.null(throttle)) {
    req <- httr2::req_throttle(
      req,
      capacity = throttle$capacity %||% 10,
      fill_time_s = throttle$fill_time_s %||% 1,
      realm = throttle$realm %||% url_host(req$url)
    )
  }
  if (!is.null(headers) && length(headers) > 0) {
    req <- do.call(
      httr2::req_headers,
      c(list(req), headers, list(.redact = names(headers)))
    )
  }
  req
}
