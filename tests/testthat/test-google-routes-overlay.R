test_that("google routes distributions overlay base distance distributions by id", {
  base <- data.frame(
    distance_distribution_id = c("dist_centralized_food_truck_2024", "dist_regionalized_food_truck_2024"),
    scenario_id = c("CENTRALIZED", "REGIONALIZED"),
    p50_miles = c(100, 80),
    status = c("OK", "OK"),
    stringsAsFactors = FALSE
  )

  routes <- data.frame(
    distance_distribution_id = c("dist_centralized_food_truck_2024", "dist_regionalized_food_truck_2024"),
    scenario_id = c("CENTRALIZED", "REGIONALIZED"),
    p50_miles = c(220, 140),
    status = c("OK", "ERROR"),
    stringsAsFactors = FALSE
  )

  out <- merge_distance_distributions(base, routes)
  expect_equal(out$p50_miles[out$distance_distribution_id == "dist_centralized_food_truck_2024"], 220)
  expect_equal(out$p50_miles[out$distance_distribution_id == "dist_regionalized_food_truck_2024"], 80)
})

