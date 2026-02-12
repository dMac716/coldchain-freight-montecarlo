test_that("validate_inputs accepts valid parameters", {
  
  inputs <- list(
    distance_km = 500,
    payload_tons = 20,
    ambient_temp_c = 20,
    fuel_efficiency_l_per_100km = 30
  )
  
  expect_silent(validate_inputs(inputs))
})


test_that("validate_inputs rejects out-of-range values", {
  
  expect_error(
    validate_inputs(list(distance_km = -100)),
    "distance_km.*>="
  )
  
  expect_error(
    validate_inputs(list(distance_km = 20000)),
    "distance_km.*<="
  )
  
  expect_error(
    validate_inputs(list(payload_tons = -5)),
    "payload_tons"
  )
  
  expect_error(
    validate_inputs(list(ambient_temp_c = -50)),
    "ambient_temp_c"
  )
  
  expect_error(
    validate_inputs(list(fuel_efficiency_l_per_100km = 5)),
    "fuel_efficiency"
  )
})


test_that("validate_inputs rejects non-numeric values", {
  
  expect_error(
    validate_inputs(list(distance_km = "500")),
    "numeric value"
  )
  
  expect_error(
    validate_inputs(list(distance_km = c(100, 200))),
    "single numeric"
  )
})


test_that("validate_inputs rejects non-finite values", {
  
  expect_error(
    validate_inputs(list(distance_km = NA)),
    "finite"
  )
  
  expect_error(
    validate_inputs(list(distance_km = Inf)),
    "finite"
  )
  
  expect_error(
    validate_inputs(list(distance_km = NaN)),
    "finite"
  )
})
