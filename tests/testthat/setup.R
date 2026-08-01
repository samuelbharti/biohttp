# Every test starts from a clean process-global state. The breaker and the cache
# are both singletons by design, so without this a test that trips the breaker
# would silently change the answer for whatever runs next.
withr::local_envvar(
  BIOHTTP_CACHE_DIR = withr::local_tempdir(.local_envir = teardown_env()),
  BIOHTTP_CACHE_SALT = "test-salt",
  BIOHTTP_CACHE_DISK = "",
  BIOHTTP_CALLER_IDENTITY = "",
  BIOHTTP_CONTACT_EMAIL = "",
  BIOHTTP_CONTACT_URL = "",
  .local_envir = teardown_env()
)

breaker_reset()
cache_reset()
