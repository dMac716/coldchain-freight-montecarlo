test_that("food inputs expose PDF-aligned product energy densities", {
  skip_if_not_installed("yaml")
  fi <- read_food_inputs(file.path("..", "..", "data"))
  expect_false(is.null(fi))
  expect_true(is.data.frame(fi$products))

  dry <- fi$products[tolower(fi$products$product_type) == "dry", , drop = FALSE]
  ref <- fi$products[tolower(fi$products$product_type) == "refrigerated", , drop = FALSE]

  expect_equal(nrow(dry), 1)
  expect_equal(nrow(ref), 1)
  expect_equal(as.numeric(dry$kcal_per_kg_label[[1]]), 3675, tolerance = 1e-9)
  expect_equal(as.numeric(ref$kcal_per_kg_label[[1]]), 2375, tolerance = 1e-9)
})

test_that("functional-unit mass conversion is algebraically consistent", {
  skip_if_not_installed("yaml")
  fi <- read_food_inputs(file.path("..", "..", "data"))
  prof <- resolve_food_profile("dry", food_inputs = fi, seed = 123)
  expect_true(is.finite(as.numeric(prof$kcal_per_kg_product)))
  expect_gt(as.numeric(prof$kcal_per_kg_product), 0)

  fu_mass <- mass_required_for_fu_kg("dry", fu_kcal = 1000, food_inputs = fi, seed = 123)
  expect_true(is.finite(fu_mass))
  expect_gt(fu_mass, 0)
  expect_equal(fu_mass * as.numeric(prof$kcal_per_kg_product), 1000, tolerance = 1e-8)
})

test_that("HOS helper inserts required break and reset events", {
  ev <- list()
  add_event <- function(t0, t1, type, lat, lng, reason = "") {
    ev[[length(ev) + 1L]] <<- data.frame(
      t_start = as.character(t0),
      t_end = as.character(t1),
      event_type = as.character(type),
      lat = as.numeric(lat),
      lng = as.numeric(lng),
      reason = as.character(reason),
      stringsAsFactors = FALSE
    )
  }

  cfg <- list(
    hos = list(
      break_after_driving_h = 8,
      break_minutes = 30,
      max_driving_h = 11,
      max_on_duty_h = 14,
      reset_off_duty_h = 10
    )
  )

  t0 <- as.POSIXct("2026-03-05 00:00:00", tz = "UTC")
  counts <- list(stop = 0L, charge = 0L, refuel = 0L)
  hos <- list(shift_driving_h = 8, shift_on_duty_h = 8, break_taken = FALSE, rest_periods = 0L)
  out <- apply_hos_rules(hos, t0, counts, add_event, lat = 38.5, lng = -121.7, cfg = cfg)

  ev_df <- do.call(rbind, ev)
  expect_true(any(ev_df$event_type == "REST_BREAK"))
  expect_equal(as.numeric(difftime(out$tcur, t0, units = "mins")), 30, tolerance = 1e-9)

  ev <- list()
  hos2 <- list(shift_driving_h = 11.1, shift_on_duty_h = 14.1, break_taken = TRUE, rest_periods = 0L)
  out2 <- apply_hos_rules(hos2, t0, counts, add_event, lat = 38.5, lng = -121.7, cfg = cfg)
  ev_df2 <- do.call(rbind, ev)
  expect_true(any(ev_df2$event_type == "REST_RESET"))
  expect_equal(as.numeric(out2$hos_state$shift_driving_h), 0, tolerance = 1e-9)
  expect_equal(as.numeric(out2$hos_state$shift_on_duty_h), 0, tolerance = 1e-9)
  expect_equal(as.integer(out2$hos_state$rest_periods), 1L)
})

test_that("trip-time rollup adds component clocks correctly", {
  x <- compute_trip_time_rollup(driving_h = 9.25, traffic_delay_h = 1.5, service_h = 2, rest_h = 10)
  expect_equal(x$driver_time_total_h, 22.75, tolerance = 1e-12)
  expect_equal(x$trip_duration_h, 22.75, tolerance = 1e-12)
})
