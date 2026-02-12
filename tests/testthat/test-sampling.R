test_that("Monte Carlo: fixed seed yields identical summaries", {
  if (!exists("run_monte_carlo_chunk")) skip("run_monte_carlo_chunk not implemented yet")

  x <- fixture_inputs_small()
  h <- fixture_hist_config()

  out1 <- run_monte_carlo_chunk(inputs = x, hist_config = h, n = 2000, seed = 123)
  out2 <- run_monte_carlo_chunk(inputs = x, hist_config = h, n = 2000, seed = 123)

  expect_equal(out1$stats$diff_gco2$mean, out2$stats$diff_gco2$mean, tolerance = 0)
  expect_equal(out1$stats$diff_gco2$var, out2$stats$diff_gco2$var, tolerance = 0)
  expect_equal(out1$hist$diff_gco2$counts, out2$hist$diff_gco2$counts)
})

test_that("Monte Carlo: different seeds should differ (usually)", {
  if (!exists("run_monte_carlo_chunk")) skip("run_monte_carlo_chunk not implemented yet")

  x <- fixture_inputs_small()
  h <- fixture_hist_config()

  out1 <- run_monte_carlo_chunk(inputs = x, hist_config = h, n = 5000, seed = 1)
  out2 <- run_monte_carlo_chunk(inputs = x, hist_config = h, n = 5000, seed = 2)

  expect_false(isTRUE(all.equal(out1$stats$diff_gco2$mean, out2$stats$diff_gco2$mean)))
})
