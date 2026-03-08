source(file.path("..", "..", "R", "08_load_model.R"), local = FALSE)
source(file.path("..", "..", "R", "sim", "10_run_bundle.R"), local = FALSE)

test_that("PACKAGING_MASS_TBD warns once per invocation in demo mode and returns policy metadata", {
  old <- Sys.getenv("REAL_RUN", unset = "")
  on.exit(Sys.setenv(REAL_RUN = old), add = TRUE)
  Sys.setenv(REAL_RUN = "0")
  options(coldchain.packaging_warned.invocation = FALSE)

  expect_message(
    p1 <- evaluate_packaging_mass_policy("dry"),
    regexp = "PACKAGING_MASS_TBD"
  )
  expect_no_message(
    p2 <- evaluate_packaging_mass_policy("dry")
  )

  expect_equal(p1$packaging_mass_policy, "DEMO_WARN_CONTINUE")
  expect_true(is.finite(as.numeric(p1$packaging_mass_tbd_count)))
  expect_true(nzchar(as.character(p1$packaging_mass_assumption_note)))
  expect_equal(p2$packaging_mass_tbd_count, p1$packaging_mass_tbd_count)
})

test_that("PACKAGING_MASS_TBD is a hard error in REAL_RUN", {
  old <- Sys.getenv("REAL_RUN", unset = "")
  on.exit(Sys.setenv(REAL_RUN = old), add = TRUE)
  Sys.setenv(REAL_RUN = "1")
  options(coldchain.packaging_warned.invocation = FALSE)

  expect_error(
    evaluate_packaging_mass_policy("dry"),
    regexp = "REAL_RUN blocked"
  )
})
