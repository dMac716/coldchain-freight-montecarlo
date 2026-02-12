test_that("validation rejects invalid triangular params", {
  if (!exists("validate_triangular_params")) skip("validate_triangular_params not implemented yet")

  expect_error(validate_triangular_params(min = 10, mode = 5, max = 20))
  expect_error(validate_triangular_params(min = 10, mode = 25, max = 20))
  expect_silent(validate_triangular_params(min = 10, mode = 15, max = 20))
})

test_that("validation rejects negative distances and negative factors", {
  if (!exists("validate_inputs")) skip("validate_inputs not implemented yet")

  x <- fixture_inputs_small()
  x$distance_miles <- -1
  expect_error(validate_inputs(x))

  x <- fixture_inputs_small()
  x$truck_g_per_ton_mile <- -5
  expect_error(validate_inputs(x))
})
