# The dependency list is a hard constraint, not a preference. Every downstream
# package and app inherits it, so a new name in Imports should fail the suite
# and force the conversation before it reaches a review.
#
# jsonlite is on the list because httr2 carries it in Suggests, not Imports:
# httr2::resp_body_json() calls check_installed("jsonlite") at runtime. Without
# it declared here, biohttp installs cleanly and then fails on the first
# get_json() call, which is the package's main entry point. It costs nothing in
# practice, since shiny imports jsonlite directly and every consumer app has it.
#
# curl is on the list for redact_secrets(), which matches curl::curl_escape()
# because that is the encoder httr2 builds query strings with. It is already a
# hard Imports of httr2, so declaring it adds nothing to what a consumer
# installs; it is named here because the package calls it directly.
#
# tools is on the list for cache_dir(), which calls tools::R_user_dir() to place
# the disk tier where CRAN sanctions a per-user cache. It is a base-priority
# package shipped with every R installation, so declaring it adds nothing to
# what a consumer installs; the same argument as curl, and it is named for the
# same reason: R CMD check wants a declaration for anything reached with `::`.
test_that("Imports stays at cachem, curl, httr2, jsonlite, rlang, and tools", {
  desc <- system.file("DESCRIPTION", package = "biohttp")
  imports <- read.dcf(desc, "Imports")[[1]]
  declared <- trimws(strsplit(imports, ",")[[1]])

  expect_setequal(
    declared,
    c("cachem", "curl", "httr2", "jsonlite", "rlang", "tools")
  )
})

test_that("no Shiny dependency in any form", {
  desc <- system.file("DESCRIPTION", package = "biohttp")
  fields <- read.dcf(desc, c("Depends", "Imports", "Suggests", "LinkingTo"))

  expect_false(any(grepl("shiny", fields, ignore.case = TRUE), na.rm = TRUE))
})

test_that("the json parser httr2 defers to is actually available", {
  # The failure this guards is silent at install time and loud at call time.
  expect_true(requireNamespace("jsonlite", quietly = TRUE))
})

# The version is written in three places and nothing reads it from one source.
# .zenodo.json is what a release is archived under and CITATION.cff is what
# GitHub renders in the cite box, so either going stale mislabels the record
# permanently, in a way no one notices until someone cites it. These files are
# in .Rbuildignore, so they are read from the source tree rather than from the
# installed package and the test is skipped when it is not run from source.
test_that("DESCRIPTION, .zenodo.json and CITATION.cff agree on the version", {
  root <- file.path(testthat::test_path(), "..", "..")
  zenodo <- file.path(root, ".zenodo.json")
  citation <- file.path(root, "CITATION.cff")
  skip_if_not(file.exists(zenodo) && file.exists(citation), "not a source tree")

  declared <- as.character(utils::packageVersion("biohttp"))

  expect_identical(jsonlite::fromJSON(zenodo)$version, declared)

  cff <- readLines(citation, warn = FALSE)
  cff_version <- trimws(sub(
    "^version:",
    "",
    grep("^version:", cff, value = TRUE)[1]
  ))
  expect_identical(gsub("[\"']", "", cff_version), declared)
})
