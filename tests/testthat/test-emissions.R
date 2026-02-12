test_that("calculate_emissions works for dry freight", {
  
  result <- calculate_emissions(
    distance_km = 500,
    payload_tons = 20,
    is_refrigerated = FALSE,
    ambient_temp_c = 20,
    fuel_efficiency_l_per_100km = 30
  )
  
  expect_type(result, "list")
  expect_named(result, c("fuel_consumption_l", "co2_emissions_kg", "total_cost_usd", "is_refrigerated"))
  expect_true(result$fuel_consumption_l > 0)
  expect_true(result$co2_emissions_kg > 0)
  expect_true(result$total_cost_usd > 0)
  expect_false(result$is_refrigerated)
  
  # Check that CO2 is calculated correctly (2.68 kg per liter)
  expect_equal(result$co2_emissions_kg, result$fuel_consumption_l * 2.68)
})


test_that("calculate_emissions works for refrigerated freight", {
  
  result <- calculate_emissions(
    distance_km = 500,
    payload_tons = 20,
    is_refrigerated = TRUE,
    ambient_temp_c = 25,
    fuel_efficiency_l_per_100km = 30
  )
  
  expect_type(result, "list")
  expect_true(result$is_refrigerated)
  
  # Refrigerated should have higher fuel consumption
  result_dry <- calculate_emissions(
    distance_km = 500,
    payload_tons = 20,
    is_refrigerated = FALSE,
    ambient_temp_c = 25,
    fuel_efficiency_l_per_100km = 30
  )
  
  expect_true(result$fuel_consumption_l > result_dry$fuel_consumption_l)
  expect_true(result$co2_emissions_kg > result_dry$co2_emissions_kg)
})


test_that("calculate_emissions respects temperature effects", {
  
  # Higher temperature should increase refrigeration load
  result_hot <- calculate_emissions(500, 20, TRUE, 35, 30)
  result_cold <- calculate_emissions(500, 20, TRUE, 15, 30)
  
  expect_true(result_hot$fuel_consumption_l > result_cold$fuel_consumption_l)
})


test_that("calculate_emissions validates inputs", {
  
  expect_error(
    calculate_emissions(-100, 20, FALSE, 20, 30),
    "distance_km"
  )
  
  expect_error(
    calculate_emissions(500, -5, FALSE, 20, 30),
    "payload_tons"
  )
  
  expect_error(
    calculate_emissions(500, 20, FALSE, 100, 30),
    "ambient_temp_c"
  )
})
