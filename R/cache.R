# The response cache.
#
# A thin wrapper over cachem with one policy: only a success is stored. This is
# not a caching library and is not trying to become one.
#
# httr2::req_cache() is deliberately not used. It only caches GET 200s carrying
# cache headers, and many of the calls this serves are header-less POSTs.

# Bumping this invalidates every cached entry at once, for when a caller's parse
# changes shape and old entries would misread.
CACHE_SCHEMA <- "1"

cache_salt <- function() {
  Sys.getenv("BIOHTTP_CACHE_SALT", "")
}

cache_dir <- function() {
  Sys.getenv("BIOHTTP_CACHE_DIR", file.path("data", "cache"))
}

# The disk tier is opt-in and off by default. A library should not start writing
# to somebody's disk because they installed it; a consumer that wants a cache
# surviving a restart asks for one.
cache_disk_enabled <- function() {
  env_flag("BIOHTTP_CACHE_DISK", default = FALSE)
}

# Built lazily on first use so the directory, and any environment override a
# test points at a tempdir, is read then rather than at load time.
cache_store <- new.env(parent = emptyenv())

# Build the disk tier, or return NULL if it will not actually work.
#
# cachem::cache_disk() does NOT error when it cannot create the directory. It
# emits a warning and hands back a normal-looking object, and the failure
# surfaces later on a real set(), in the middle of a call. So constructing it is
# not proof that it works: write one probe entry and read it back before
# trusting it. The apps this serves run in containers with no writable volume,
# where that distinction is the difference between degrading and crashing.
disk_tier <- function() {
  disk <- tryCatch(
    cachem::cache_disk(
      dir = cache_dir(),
      max_age = env_num("BIOHTTP_CACHE_DISK_TTL", 7 * 24 * 3600),
      evict = "lru"
    ),
    error = function(e) NULL,
    warning = function(w) NULL
  )
  if (is.null(disk)) {
    return(NULL)
  }
  usable <- tryCatch(
    {
      # cachem keys are lowercase letters and numbers only, so no separator.
      disk$set("biohttpprobe", TRUE)
      hit <- isTRUE(disk$get("biohttpprobe"))
      disk$remove("biohttpprobe")
      hit
    },
    error = function(e) FALSE,
    warning = function(w) FALSE
  )
  if (isTRUE(usable)) disk else NULL
}

build_cache <- function() {
  # Three ceilings, because they bound different things and a cache can blow
  # through one while sitting comfortably inside the others. max_size bounds
  # bytes, which a long-running process answering many small responses can stay
  # under while still accumulating far more entries than intended, so max_n
  # bounds the count separately. Its default is cachem's own Inf, so a caller
  # who does not set it sees no change.
  mem <- cachem::cache_mem(
    max_age = env_num("BIOHTTP_CACHE_TTL", 1800),
    max_size = env_num("BIOHTTP_CACHE_MAX_SIZE", 256 * 1024^2),
    max_n = env_num("BIOHTTP_CACHE_MAX_N", Inf),
    evict = "lru"
  )
  if (!cache_disk_enabled()) {
    return(mem)
  }
  # Disk is a best effort even once asked for. An unusable directory degrades to
  # memory-only rather than failing, which is what lets the same code run in a
  # container with no writable volume.
  disk <- disk_tier()
  if (is.null(disk)) mem else cachem::cache_layered(mem, disk)
}

#' The cache store
#'
#' The `cachem` object backing [cached()]. Memory-only unless
#' `BIOHTTP_CACHE_DISK` asks for the disk tier, in which case the two are
#' layered. Built on first use.
#'
#' @return A `cachem` cache object.
#'
#' @examples
#' cache_reset()
#' class(cache())[1]
#'
#' @export
cache <- function() {
  if (is.null(cache_store$store)) {
    cache_store$store <- build_cache()
  }
  cache_store$store
}

#' Drop the cache store
#'
#' Forgets the singleton so the next [cache()] rebuilds it, picking up any
#' changed environment settings. Tests use this to isolate, after pointing
#' `BIOHTTP_CACHE_DIR` at a fresh tempdir.
#'
#' @return `NULL`, invisibly.
#'
#' @examples
#' cache_reset()
#'
#' @export
cache_reset <- function() {
  cache_store$store <- NULL
  invisible(NULL)
}

# cache_layered's get() takes only `key` and returns cachem's key_missing
# sentinel when absent, so normalize that to NULL.
cache_get <- function(key) {
  val <- cache()$get(key)
  if (cachem::is.key_missing(val)) NULL else val
}

#' Build a cache key
#'
#' A stable lowercase-hex hash. `cachem` keys may contain only lowercase
#' letters and numbers, so a URL cannot be one directly and the inputs are
#' hashed instead. `rlang::hash()` returns lowercase hex, which satisfies the
#' rule.
#'
#' The salt and the schema version are inside the hash, so changing either
#' yields a fresh keyspace. Set `BIOHTTP_CACHE_SALT` per deployment: a shared
#' disk cache would otherwise collide across app versions, and it would leak
#' which queries were run to anyone able to probe it.
#'
#' **Put anything that changes the answer into `params`, credentials
#' included.** The wrappers pass their `headers` through, because two callers
#' hitting the same URL with different tokens can legitimately get different
#' responses, and keying on the URL alone would serve one caller's data to the
#' other. The cost is that rotating a token misses the cache once, which is the
#' right trade.
#'
#' @param source A friendly label for the service.
#' @param key Something identifying the call, usually the method and URL.
#' @param params Anything else that changes the answer, such as a POST body.
#'
#' @return A single string.
#'
#' @examples
#' cache_key("gnomAD", "GET https://example.org/v1/gene/BRCA1")
#' cache_key("gnomAD", "POST https://example.org/graphql", list(q = "BRCA1"))
#'
#' @export
cache_key <- function(source, key, params = NULL) {
  rlang::hash(list(
    schema = CACHE_SCHEMA,
    salt = cache_salt(),
    source = source,
    key = key,
    params = params
  ))
}

#' Serve from cache, or fetch and cache a success
#'
#' Returns a cached result for `key` if there is one, otherwise runs `fetch()`
#' and stores the result only when it succeeded.
#'
#' **A failure is never cached.** This is the single most important rule in the
#' package. A cache that stores an error fallback poisons itself for the life of
#' the R process, and every later lookup then serves the stored failure instead
#' of retrying. Storing only successes means a transient outage resolves itself
#' the moment the source comes back.
#'
#' @param key A key from [cache_key()].
#' @param fetch A function of no arguments returning an envelope.
#'
#' @return The envelope, from the cache or from `fetch()`.
#'
#' @examples
#' cache_reset()
#' key <- cache_key("demo", "GET /x")
#' cached(key, function() status_ok(data = list(n = 1), source = "demo"))
#'
#' # A failure runs fetch() again every time.
#' bad <- cache_key("demo", "GET /y")
#' cached(bad, function() status_error(source = "demo"))
#'
#' @export
cached <- function(key, fetch) {
  hit <- cache_get(key)
  if (!is.null(hit)) {
    return(hit)
  }
  res <- fetch()
  if (isTRUE(res$ok)) {
    cache()$set(key, res)
  }
  res
}
