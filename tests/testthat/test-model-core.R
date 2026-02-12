test_that("deterministic model: zero distance implies zero emissions", {
  if (!exists("compute_emissions_deterministic")) skip("compute_emissions_deterministic not implemented yet")

  x <- fixture_inputs_small()
  x$distance_miles <- 0

  out <- compute_emissions_deterministic(x)
  expect_equal(out$gco2_dry, 0, tolerance = 1e-12)
  expect_equal(out$gco2_reefer, 0, tolerance = 1e-12)
  expect_equal(out$diff_gco2, 0, tolerance = 1e-12)
})

test_that("deterministic model: linearity in distance", {
  if (!exists("compute_emissions_deterministic")) skip("compute_emissions_deterministic not implemented yet")

  x1 <- fixture_inputs_small()
  x2 <- fixture_inputs_small()
  x2$distance_miles <- x1$distance_miles * 2

  out1 <- compute_emissions_deterministic(x1)
  out2 <- compute_emissions_deterministic(x2)

  expect_equal(out2$gco2_dry, out1$gco2_dry * 2, tolerance = 1e-10)
  expect_equal(out2$gco2_reefer, out1$gco2_reefer * 2, tolerance = 1e-10)
  expect_equal(out2$diff_gco2, out1$diff_gco2 * 2, tolerance = 1e-10)
})

test_that("deterministic model: penalty zero and equal masses implies equality", {
  if (!exists("compute_emissions_deterministic")) skip("compute_emissions_deterministic not implemented yet")

  x <- fixture_inputs_small()
  # Force equal product energy density and packaging so masses match
  x$kcal_per_kg_reefer <- x$kcal_per_kg_dry
  x$pkg_kg_per_kg_reefer <- x$pkg_kg_per_kg_dry
  x$reefer_extra_g_per_ton_mile <- 0
  x$util_reefer <- x$util_dry

  out <- compute_emissions_deterministic(x)
  expect_equal(out$gco2_reefer, out$gco2_dry, tolerance = 1e-10)
  expect_equal(out$diff_gco2, 0, tolerance = 1e-10)
  expect_equal(out$ratio, 1, tolerance = 1e-10)
})
