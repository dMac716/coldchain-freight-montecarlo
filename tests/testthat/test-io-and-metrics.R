test_that("build_sampling_from_factors returns empty for sourced factor schema", {
  factors <- utils::read.csv(file.path("..", "..", "data", "inputs_local", "factors.csv"), stringsAsFactors = FALSE)
  sampling <- build_sampling_from_factors(factors, scenario_name = "BASE")
  expect_type(sampling, "list")
  expect_length(sampling, 0)
})

test_that("metric moments are internally consistent", {
  x <- fixture_inputs_small()
  h <- fixture_hist_config()
  out <- run_monte_carlo_chunk(inputs = x, hist_config = h, n = 2500, seed = 99)

  m <- out$stats$diff_gco2
  expect_equal(m$mean, m$sum / m$n, tolerance = 1e-12)
  expect_equal(m$var, (m$sum_sq / m$n) - (m$mean^2), tolerance = 1e-10)
  expect_true(m$min <= m$mean)
  expect_true(m$mean <= m$max)
})

test_that("histogram tracks underflow and overflow counts", {
  h <- make_histogram(c(-10, 0.5, 2.5, 5), bin_edges = c(0, 1, 2))
  expect_equal(h$underflow, 1)
  expect_equal(h$overflow, 2)
  expect_equal(sum(h$counts), 1)
})
