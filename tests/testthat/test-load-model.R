source(file.path("..", "..", "R", "sim", "01_build_route_segments.R"), local = FALSE)
source(file.path("..", "..", "R", "sim", "07_event_simulator.R"), local = FALSE)
source(file.path("..", "..", "R", "08_load_model.R"), local = FALSE)

test_that("deterministic seed gives stable units_per_truck", {
  cfg <- list(
    load_model = list(
      trailer = list(
        pallets_max = 26,
        payload_max_lb = list(distribution = list(type = "triangular", min = 38000, mode = 43000, max = 45000))
      ),
      products = list(
        dry = list(
          unit_weight_lb = 30,
          bags_per_pallet = list(distribution = list(type = "triangular", min = 40, mode = 50, max = 65))
        ),
        refrigerated = list(
          unit_weight_lb = 4.5,
          packs_per_case = 6,
          cases_per_pallet = list(distribution = list(type = "triangular", min = 60, mode = 75, max = 90))
        )
      )
    )
  )

  a <- resolve_load_draw(seed = 123, cfg = cfg, product_type = "dry")
  b <- resolve_load_draw(seed = 123, cfg = cfg, product_type = "dry")
  expect_equal(a$units_per_truck, b$units_per_truck)
  expect_equal(a$payload_max_lb_draw, b$payload_max_lb_draw)
})

test_that("units_per_truck respects both pallet cube and payload weight limits", {
  units <- compute_units_per_truck(
    payload_max_lb = 43000,
    pallets_max = 26,
    unit_weight_lb = 30,
    cube_units_per_pallet = 50
  )
  expect_true(units <= 26 * 50)
  expect_true(units <= floor(43000 / 30))
})

