test_that("Histogram quantiles are monotonic", {
  if (!exists("make_histogram")) skip("make_histogram not implemented yet")
  if (!exists("hist_quantile")) skip("hist_quantile not implemented yet")

  x <- c(-2, -1, 0, 1, 2, 3, 4, 5)
  h <- make_histogram(x, bin_edges = seq(-5, 5, by = 1))

  q05 <- hist_quantile(h, 0.05)
  q50 <- hist_quantile(h, 0.50)
  q95 <- hist_quantile(h, 0.95)

  expect_true(q05 <= q50)
  expect_true(q50 <= q95)
})
