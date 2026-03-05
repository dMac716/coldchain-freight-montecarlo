source(file.path("..", "..", "R", "sim", "08_outputs.R"), local = FALSE)

test_that("summarize_route_sim_runs keeps traffic_mode split", {
  d <- data.frame(
    run_id = c("a", "b", "c", "d"),
    scenario = c("s1", "s1", "s1", "s1"),
    powertrain = c("bev", "bev", "bev", "bev"),
    traffic_mode = c("stochastic", "freeflow", "stochastic", "freeflow"),
    status = c("OK", "OK", "OK", "PLAN_SOC_VIOLATION"),
    co2_kg_total = c(100, 90, 110, 95),
    stringsAsFactors = FALSE
  )
  out <- summarize_route_sim_runs(d)
  expect_true("traffic_mode" %in% names(out))
  expect_equal(sort(unique(out$traffic_mode)), c("freeflow", "stochastic"))
  expect_equal(out$n_runs[out$traffic_mode == "stochastic"], 2)
  expect_equal(out$n_runs[out$traffic_mode == "freeflow"], 2)
})
