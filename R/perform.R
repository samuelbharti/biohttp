# Perform, and the convenience wrappers over it.
#
# perform() is where the three failure classes are told apart, and getting that
# separation right is most of the reason this package exists:
#
#   1. Transport failure. No HTTP response at all. The host may be down, so this
#      counts against the breaker.
#   2. A non-2xx response. The host answered, so it is reachable. The status
#      maps onto the enum and the breaker is cleared.
#   3. A 2xx whose body will not parse. The host answered, so it is reachable.
#      This is a data error for this call, not a reason to stop dispatching to
#      the host.
#
# Only the first of the three touches the breaker as a failure. Three of the
# four app-local layers this replaces got that wrong in one direction or
# another, by wrapping the body parse in the same tryCatch as the request and
# then reading a missing status code as "the host is down".

#' Perform a request and normalize the result
#'
#' Never raises on an HTTP or a parse failure. Returns an envelope for every
#' outcome, so a caller branches on `res$status` and writes no `tryCatch()` of
#' its own.
#'
#' Short-circuits to a `skipped` envelope without sending anything when the
#' host's breaker is open. See [breaker_open()].
#'
#' The request must have been through [req_defaults()], which disarms httr2's
#' error raising. Without that, `req_perform()` throws on a non-2xx and a
#' perfectly reachable host is recorded as a transport failure.
#'
#' @param req An httr2 request, prepared with [req_defaults()].
#' @param source A friendly label for the service, used in the user-facing
#'   message. For example `"gnomAD"`.
#'
#' @return An envelope. See [envelope()].
#'
#' @examples
#' breaker_reset()
#' req <- req_defaults(httr2::request("https://mock.test/x"))
#'
#' httr2::with_mocked_responses(
#'   list(httr2::response(
#'     status_code = 200,
#'     headers = list(`content-type` = "application/json"),
#'     body = charToRaw('{"symbol":"BRCA1"}')
#'   )),
#'   perform(req, "MyGene")$data$symbol
#' )
#'
#' @export
perform <- function(req, source = "API") {
  host <- url_host(req$url)
  if (breaker_open(host)) {
    return(status_skipped(
      source = source,
      detail = paste0(host, " breaker open")
    ))
  }
  # Only a transport failure trips the breaker, so the request itself is the
  # sole thing wrapped here. Once a response is in hand the host is reachable,
  # even for a 5xx or an unparsable body, and body parsing must not be mistaken
  # for the host being down. req_error() is disarmed in req_defaults(), so
  # req_perform() only throws on a genuine transport failure.
  resp <- tryCatch(httr2::req_perform(req), error = function(e) e)
  if (inherits(resp, "condition")) {
    breaker_record(host, reachable = FALSE)
    return(envelope(
      classify_condition(resp),
      source = source,
      http = NA_integer_,
      error = http_error_message(source, condition = resp),
      detail = paste0("Could not reach ", source, ": ", conditionMessage(resp))
    ))
  }
  http <- httr2::resp_status(resp)
  breaker_record(host, reachable = TRUE)
  if (http < 200 || http >= 300) {
    return(envelope(
      classify_http(http),
      source = source,
      http = http,
      error = http_error_message(source, http = http),
      detail = paste0(source, " returned HTTP ", http)
    ))
  }
  body <- tryCatch(
    httr2::resp_body_json(resp, check_type = FALSE, simplifyVector = FALSE),
    error = function(e) e
  )
  if (inherits(body, "condition")) {
    # A 2xx whose body is not the JSON we expected: an HTML error page, a proxy
    # interstitial, a truncated response. The host answered, so the breaker was
    # already cleared above and stays cleared.
    return(status_error(
      source = source,
      http = http,
      error = http_error_message(source, http = http),
      detail = paste0(
        source,
        " returned an unreadable body: ",
        conditionMessage(body)
      )
    ))
  }
  status_ok(data = body, source = source, http = http)
}

#' Perform a request and return the body as text
#'
#' The non-JSON counterpart to [perform()], for a source that ships a bulk flat
#' file rather than a per-record JSON API. The body lands in `data` as a single
#' string, so the envelope shape is the same either way and a caller does not
#' branch on which wrapper it used.
#'
#' The breaker rule is the same one: only a transport failure counts against the
#' host.
#'
#' @inheritParams perform
#'
#' @return An envelope whose `data` is a single string on success.
#'
#' @examples
#' breaker_reset()
#' req <- req_defaults(httr2::request("https://mock.test/genes.tsv"))
#'
#' httr2::with_mocked_responses(
#'   list(httr2::response(
#'     status_code = 200,
#'     body = charToRaw("gene\tscore\n")
#'   )),
#'   perform_text(req, "ClinGen")$data
#' )
#'
#' @export
perform_text <- function(req, source = "API") {
  host <- url_host(req$url)
  if (breaker_open(host)) {
    return(status_skipped(
      source = source,
      detail = paste0(host, " breaker open")
    ))
  }
  resp <- tryCatch(httr2::req_perform(req), error = function(e) e)
  if (inherits(resp, "condition")) {
    breaker_record(host, reachable = FALSE)
    return(envelope(
      classify_condition(resp),
      source = source,
      http = NA_integer_,
      error = http_error_message(source, condition = resp),
      detail = paste0("Could not reach ", source, ": ", conditionMessage(resp))
    ))
  }
  http <- httr2::resp_status(resp)
  breaker_record(host, reachable = TRUE)
  if (http < 200 || http >= 300) {
    return(envelope(
      classify_http(http),
      source = source,
      http = http,
      error = http_error_message(source, http = http),
      detail = paste0(source, " returned HTTP ", http)
    ))
  }
  body <- tryCatch(httr2::resp_body_string(resp), error = function(e) e)
  if (inherits(body, "condition")) {
    return(status_error(
      source = source,
      http = http,
      error = http_error_message(source, http = http),
      detail = paste0(
        source,
        " returned an unreadable body: ",
        conditionMessage(body)
      )
    ))
  }
  status_ok(data = body, source = source, http = http)
}

# Assemble a GET request from a base URL, an optional path, and a query. Blank
# query values are dropped so a request never sends "param=" with nothing after
# it, which some sources treat as a filter on the empty string.
build_get <- function(base_url, path, query) {
  req <- httr2::request(base_url)
  if (!is.null(path)) {
    req <- httr2::req_url_path_append(req, path)
  }
  if (length(query)) {
    query <- query[!vapply(query, is_blank, logical(1))]
  }
  if (length(query)) {
    req <- do.call(httr2::req_url_query, c(list(req), query))
  }
  req
}

#' GET a JSON endpoint
#'
#' Assembles the request, applies [req_defaults()], performs it, and caches the
#' result if it succeeded.
#'
#' @param base_url The service's base URL.
#' @param path An optional path appended to `base_url`.
#' @param query A named list of query parameters. Blank values are dropped.
#' @param source A friendly label for the service.
#' @param timeout Seconds before the request is abandoned.
#' @param max_tries Total attempts, including the first.
#' @param headers A named list of headers, all marked sensitive.
#' @param throttle An optional throttle spec. See [req_defaults()].
#'
#' @return An envelope. See [envelope()].
#'
#' @examples
#' # Mocked so the example runs offline. A real call drops the
#' # with_mocked_responses() wrapper.
#' cache_reset()
#' breaker_reset()
#'
#' httr2::with_mocked_responses(
#'   list(httr2::response(
#'     status_code = 200,
#'     headers = list(`content-type` = "application/json"),
#'     body = charToRaw('{"hits":[{"symbol":"BRCA1"}]}')
#'   )),
#'   get_json(
#'     "https://mygene.info/v3",
#'     path = "query",
#'     query = list(q = "BRCA1", species = "human"),
#'     source = "MyGene"
#'   )$data$hits[[1]]$symbol
#' )
#'
#' @export
get_json <- function(
  base_url,
  path = NULL,
  query = list(),
  source = "API",
  timeout = 15,
  max_tries = 3,
  headers = NULL,
  throttle = NULL
) {
  req <- build_get(base_url, path, query)
  req <- req_defaults(req, timeout, max_tries, headers, throttle)
  key <- cache_key(source, paste0("GET ", req$url))
  cached(key, function() perform(req, source))
}

#' POST a JSON body
#'
#' For a JSON or GraphQL POST. Caches on the URL and the body together, so two
#' different queries to the same endpoint do not collide.
#'
#' @param url The endpoint URL.
#' @param body A list, serialized as the JSON request body.
#' @inheritParams get_json
#'
#' @return An envelope. See [envelope()].
#'
#' @examples
#' cache_reset()
#' breaker_reset()
#'
#' httr2::with_mocked_responses(
#'   list(httr2::response(
#'     status_code = 200,
#'     headers = list(`content-type` = "application/json"),
#'     body = charToRaw('{"data":{"gene":{"gene_id":"ENSG00000012048"}}}')
#'   )),
#'   post_json(
#'     "https://gnomad.broadinstitute.org/api",
#'     body = list(query = "{ gene(gene_symbol: \"BRCA1\") { gene_id } }"),
#'     source = "gnomAD"
#'   )$data$data$gene$gene_id
#' )
#'
#' @export
post_json <- function(
  url,
  body,
  source = "API",
  timeout = 20,
  max_tries = 3,
  headers = NULL,
  throttle = NULL
) {
  req <- httr2::req_body_json(httr2::request(url), body)
  req <- req_defaults(req, timeout, max_tries, headers, throttle)
  key <- cache_key(source, paste0("POST ", url), body)
  cached(key, function() perform(req, source))
}

#' GET a text endpoint
#'
#' For a source that ships a bulk flat file, CSV or TSV, rather than a
#' per-record JSON API. Same timeout, retry, caching, and header redaction as
#' [get_json()]; the body comes back verbatim as a string in `data`.
#'
#' The success-only cache means the file is fetched once per URL and every later
#' lookup against it is served in process.
#'
#' @inheritParams get_json
#'
#' @return An envelope whose `data` is a single string on success.
#'
#' @examples
#' cache_reset()
#' breaker_reset()
#'
#' httr2::with_mocked_responses(
#'   list(httr2::response(
#'     status_code = 200,
#'     body = charToRaw("gene\tclassification\nBRCA1\tDefinitive\n")
#'   )),
#'   get_text(
#'     "https://search.clinicalgenome.org",
#'     path = "kb/gene-validity/download",
#'     source = "ClinGen"
#'   )$data
#' )
#'
#' @export
get_text <- function(
  base_url,
  path = NULL,
  query = list(),
  source = "API",
  timeout = 30,
  max_tries = 3,
  headers = NULL,
  throttle = NULL
) {
  req <- build_get(base_url, path, query)
  req <- req_defaults(req, timeout, max_tries, headers, throttle)
  key <- cache_key(source, paste0("GET_TEXT ", req$url))
  cached(key, function() perform_text(req, source))
}
