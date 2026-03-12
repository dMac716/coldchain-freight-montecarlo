test_that("build_sampling_from_factors returns empty for sourced factor schema", {
  factors <- utils::read.csv(file.path("..", "..", "data", "inputs_local", "factors.csv"), stringsAsFactors = FALSE)
  sampling <- build_sampling_from_factors(factors, scenario_name = "BASE")
  expect_type(sampling, "list")
  expect_length(sampling, 0)
})

test_that("sampling priors are valid and cover required params for smoke variant", {
  inputs <- read_inputs_local(file.path("..", "..", "data", "inputs_local"))
  expect_silent(validate_sampling_priors(inputs$sampling_priors))

  smoke <- select_variant_rows(inputs, "SMOKE_LOCAL")[1, , drop = FALSE]
  priors <- build_sampling_from_priors(inputs$sampling_priors, variant_row = smoke)
  expect_silent(assert_required_priors_present(priors, required_model_param_ids()))
})

test_that("scenarios marked OK have valid distance ids", {
  scenarios <- utils::read.csv(file.path("..", "..", "data", "inputs_local", "scenarios.csv"), stringsAsFactors = FALSE)
  dists <- utils::read.csv(file.path("..", "..", "data", "derived", "faf_distance_distributions.csv"), stringsAsFactors = FALSE)
  expect_silent(assert_scenarios_distance_linkage(scenarios, dists))
})

test_that("SMOKE_LOCAL resolves BEV variant without fallback warnings", {
  inputs <- read_inputs_local(file.path("..", "..", "data", "inputs_local"))
  bev <- select_variant_rows(inputs, "CENTRALIZED_BEV_DRY")[1, , drop = FALSE]
  expect_silent(resolve_variant_inputs(inputs, bev, mode = "SMOKE_LOCAL"))
})

test_that("all BEV scenario matrix rows resolve to non-NA runtime intensity", {
  inputs <- read_inputs_local(file.path("..", "..", "data", "inputs_local"))
  bev_rows <- subset(inputs$scenario_matrix, powertrain == "bev")
  expect_true(nrow(bev_rows) > 0)
  for (i in seq_len(nrow(bev_rows))) {
    v <- bev_rows[i, , drop = FALSE]
    r <- resolve_variant_inputs(inputs, v, mode = "SMOKE_LOCAL")
    expect_true(is.finite(r$inputs_list$truck_g_per_ton_mile), info = v$variant_id[[1]])
    expect_true(is.finite(r$inputs_list$reefer_extra_g_per_ton_mile), info = v$variant_id[[1]])
  }
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

test_that("write_results_summary supports omitted histograms", {
  stats <- list(
    gco2 = list(mean = 1, var = 0.25, min = 0.5, max = 1.5)
  )
  out <- tempfile(fileext = ".csv")
  write_results_summary(stats, out, hist = NULL)
  expect_true(file.exists(out))
  d <- utils::read.csv(out, stringsAsFactors = FALSE)
  expect_identical(names(d), c("metric", "mean", "var", "min", "max", "p05", "p50", "p95"))
  expect_true(all(is.na(d$p05)))
  expect_true(all(is.na(d$p50)))
  expect_true(all(is.na(d$p95)))
})
