test_that("Golden deterministic outputs remain stable", {
  if (!exists("compute_emissions_deterministic")) skip("compute_emissions_deterministic not implemented yet")

  x <- fixture_inputs_small()
  out <- compute_emissions_deterministic(x)
  golden <- fixture_golden()

  if (any(is.na(unlist(golden)))) {
    skip("Golden values not yet set. Populate fixture_golden() once core model is finalized.")
  }

  expect_equal(out$gco2_dry, golden$gco2_dry, tolerance = 1e-10)
  expect_equal(out$gco2_reefer, golden$gco2_reefer, tolerance = 1e-10)
  expect_equal(out$diff_gco2, golden$diff_gco2, tolerance = 1e-10)
  expect_equal(out$ratio, golden$ratio, tolerance = 1e-10)
})
