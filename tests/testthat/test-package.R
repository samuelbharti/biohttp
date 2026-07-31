# The dependency list is a hard constraint, not a preference. Every downstream
# package and app inherits it, so a new name in Imports should fail the suite
# and force the conversation before it reaches a review.
#
# jsonlite is on the list because httr2 carries it in Suggests, not Imports:
# httr2::resp_body_json() calls check_installed("jsonlite") at runtime. Without
# it declared here, biohttp installs cleanly and then fails on the first
# get_json() call, which is the package's main entry point. It costs nothing in
# practice, since shiny imports jsonlite directly and every consumer app has it.
test_that("Imports stays at cachem, httr2, jsonlite, and rlang", {
  desc <- system.file("DESCRIPTION", package = "biohttp")
  imports <- read.dcf(desc, "Imports")[[1]]
  declared <- trimws(strsplit(imports, ",")[[1]])

  expect_setequal(declared, c("cachem", "httr2", "jsonlite", "rlang"))
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
