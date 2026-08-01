# The dependency list is a hard constraint, not a preference. Every downstream
# package and app inherits it, so a new name in Imports should fail the suite and
# force the conversation before it reaches a review.
test_that("Imports stays at cachem, httr2, and rlang", {
  desc <- system.file("DESCRIPTION", package = "biohttp")
  imports <- read.dcf(desc, "Imports")[[1]]
  declared <- trimws(strsplit(imports, ",")[[1]])

  expect_setequal(declared, c("cachem", "httr2", "rlang"))
})

test_that("no Shiny dependency in any form", {
  desc <- system.file("DESCRIPTION", package = "biohttp")
  fields <- read.dcf(desc, c("Depends", "Imports", "Suggests", "LinkingTo"))

  expect_false(any(grepl("shiny", fields, ignore.case = TRUE), na.rm = TRUE))
})
