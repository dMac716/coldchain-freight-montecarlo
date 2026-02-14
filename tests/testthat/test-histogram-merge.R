test_that("Histogram merge: merged counts equal sum of counts", {
  if (!exists("merge_histograms")) skip("merge_histograms not implemented yet")
  if (!exists("run_monte_carlo_chunk")) skip("run_monte_carlo_chunk not implemented yet")

  x <- fixture_inputs_small()
  h <- fixture_hist_config()

  c1 <- run_monte_carlo_chunk(inputs = x, hist_config = h, n = 3000, seed = 10)
  c2 <- run_monte_carlo_chunk(inputs = x, hist_config = h, n = 4000, seed = 11)

  merged <- merge_histograms(list(c1$hist$diff_gco2, c2$hist$diff_gco2))

  expect_equal(merged$counts, c1$hist$diff_gco2$counts + c2$hist$diff_gco2$counts)
  expect_equal(merged$underflow, c1$hist$diff_gco2$underflow + c2$hist$diff_gco2$underflow)
  expect_equal(merged$overflow, c1$hist$diff_gco2$overflow + c2$hist$diff_gco2$overflow)
})

test_that("Moment merge: merged mean and variance match algebra", {
  if (!exists("merge_moments")) skip("merge_moments not implemented yet")
  if (!exists("run_monte_carlo_chunk")) skip("run_monte_carlo_chunk not implemented yet")

  x <- fixture_inputs_small()
  h <- fixture_hist_config()

  c1 <- run_monte_carlo_chunk(inputs = x, hist_config = h, n = 3000, seed = 21)
  c2 <- run_monte_carlo_chunk(inputs = x, hist_config = h, n = 5000, seed = 22)

  m <- merge_moments(list(c1$stats$diff_gco2, c2$stats$diff_gco2))

  n <- c1$stats$diff_gco2$n + c2$stats$diff_gco2$n
  sum_ <- c1$stats$diff_gco2$sum + c2$stats$diff_gco2$sum
  sumsq <- c1$stats$diff_gco2$sum_sq + c2$stats$diff_gco2$sum_sq
  mu <- sum_ / n
  var_pop <- (sumsq / n) - mu^2

  expect_equal(m$n, n)
  expect_equal(m$mean, mu, tolerance = 1e-12)
  expect_equal(m$var, var_pop, tolerance = 1e-10)
})

test_that("Histogram merge rejects mismatched bin edges", {
  if (!exists("merge_histograms")) skip("merge_histograms not implemented yet")

  h1 <- make_histogram(c(1, 2, 3), bin_edges = c(0, 1, 2, 3, 4))
  h2 <- make_histogram(c(1, 2, 3), bin_edges = c(0, 2, 4, 6, 8))
  expect_error(merge_histograms(list(h1, h2)))
})
