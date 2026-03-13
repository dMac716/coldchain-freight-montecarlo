# Load and packaging model helpers (geometry-driven case-on-pallet).

infer_product_type_from_text <- function(x, default = "refrigerated") {
  s <- tolower(as.character(x %||% ""))
  if (grepl("dry", s, fixed = TRUE)) return("dry")
  if (grepl("refriger", s, fixed = TRUE)) return("refrigerated")
  tolower(as.character(default %||% "refrigerated"))
}

cold_chain_required_from_product_type <- function(product_type, default = TRUE) {
  pt <- infer_product_type_from_text(product_type, default = if (isTRUE(default)) "refrigerated" else "dry")
  identical(pt, "refrigerated")
}

is_real_run_env <- function() {
  v <- tolower(trimws(Sys.getenv("REAL_RUN", unset = "0")))
  v %in% c("1", "true", "yes", "y")
}

sample_trailer_capacity <- function(seed, test_kit) {
  rng <- new_rng(seed)
  lm <- test_kit$load_model %||% list()
  tr <- lm$trailer %||% list()
  list(
    payload_max_lb = as.numeric(sim_pick_distribution(tr$payload_max_lb, rng = rng)),
    pallets_max = as.integer(tr$pallets_max %||% 26L)
  )
}

compute_cases_per_layer <- function(pallet_L, pallet_W, case_L, case_W, clearance_xy) {
  usable_L <- max(0, as.numeric(pallet_L) - 2 * as.numeric(clearance_xy))
  usable_W <- max(0, as.numeric(pallet_W) - 2 * as.numeric(clearance_xy))
  if (!all(is.finite(c(usable_L, usable_W, case_L, case_W))) || case_L <= 0 || case_W <= 0) return(0L)
  a <- floor(usable_L / case_L) * floor(usable_W / case_W)
  b <- floor(usable_L / case_W) * floor(usable_W / case_L)
  as.integer(max(0, a, b))
}

compute_layers <- function(max_stack_height_in, case_H, clearance_z, fail_if_less_than_one = is_real_run_env()) {
  usable_H <- max(0, as.numeric(max_stack_height_in) - as.numeric(clearance_z))
  if (!all(is.finite(c(usable_H, case_H))) || case_H <= 0) {
    if (isTRUE(fail_if_less_than_one)) stop("Invalid case/pallet height config for REAL_RUN.")
    return(1L)
  }
  layers <- floor(usable_H / case_H)
  if (layers < 1) {
    if (isTRUE(fail_if_less_than_one)) stop("Computed layers < 1 for REAL_RUN; adjust case height or stack height.")
    return(1L)
  }
  as.integer(layers)
}

pick_refrigerated_case_dims <- function(prod, pattern_idx) {
  ud <- prod$unit_dims_in %||% list(L = 6.99, W = 7.99, H = 10.32)
  pats <- prod$case_pack_patterns %||% list(
    list(nx = 5, ny = 1, void_xy_pct = 0.12, void_z_pct = 0.08),
    list(nx = 3, ny = 2, void_xy_pct = 0.12, void_z_pct = 0.08),
    list(nx = 2, ny = 3, void_xy_pct = 0.12, void_z_pct = 0.08)
  )
  idx <- max(1L, min(as.integer(pattern_idx %||% 1L), length(pats)))
  p <- pats[[idx]]
  nx <- as.integer(p$nx %||% 1L)
  ny <- as.integer(p$ny %||% 1L)
  vxy <- as.numeric(p$void_xy_pct %||% 0)
  vz <- as.numeric(p$void_z_pct %||% 0)
  bL <- as.numeric(ud$L %||% NA_real_)
  bW <- as.numeric(ud$W %||% NA_real_)
  bH <- as.numeric(ud$H %||% NA_real_)

  L1 <- nx * bL * (1 + vxy)
  W1 <- ny * bW * (1 + vxy)
  L2 <- nx * bW * (1 + vxy)
  W2 <- ny * bL * (1 + vxy)
  if (is.finite(L2 * W2) && (!is.finite(L1 * W1) || (L2 * W2) < (L1 * W1))) {
    case_L <- L2
    case_W <- W2
  } else {
    case_L <- L1
    case_W <- W1
  }
  case_H <- bH * (1 + vz)

  list(
    nx = nx,
    ny = ny,
    void_xy_pct = vxy,
    void_z_pct = vz,
    case_L = case_L,
    case_W = case_W,
    case_H = case_H,
    pattern_index = idx
  )
}

sample_product_packaging <- function(seed, product_type, test_kit) {
  rng <- new_rng(seed)
  lm <- test_kit$load_model %||% list()
  pt <- infer_product_type_from_text(product_type)
  prod <- lm$products[[pt]] %||% list()
  pkg <- lm$packaging %||% list()
  pal <- lm$pallet %||% list()

  units_per_case_draw <- as.numeric(sim_pick_distribution(prod$units_per_case, rng = rng))
  unit_weight_lb <- as.numeric(prod$unit_weight_lb %||% NA_real_)
  pallet_tare_lb_draw <- as.numeric(sim_pick_distribution(pkg$pallet_tare_lb, rng = rng))
  case_tare_lb_draw <- as.numeric(sim_pick_distribution(pkg$case_tare_lb[[pt]], rng = rng))
  packing_efficiency_draw <- as.numeric(sim_pick_distribution(pal$packing_efficiency, rng = rng))

  pallet_L <- as.numeric(pal$length_in %||% 48)
  pallet_W <- as.numeric(pal$width_in %||% 40)
  clearance_xy <- as.numeric(pal$clearance_xy_in %||% 1.0)
  clearance_z <- as.numeric(pal$clearance_z_in %||% 2.0)
  max_stack_height_in <- as.numeric((pal$max_stack_height_in %||% list())[[pt]] %||% if (identical(pt, "dry")) 84 else 72)

  chosen_pack_pattern <- NA_character_
  pack_pattern_index <- NA_integer_
  if (identical(pt, "dry")) {
    cd <- prod$case_dims_in %||% list(L = 24, W = 16, H = 6)
    case_L <- as.numeric(cd$L %||% 24)
    case_W <- as.numeric(cd$W %||% 16)
    case_H <- as.numeric(cd$H %||% 6)
  } else {
    pats <- prod$case_pack_patterns %||% list(
      list(nx = 5, ny = 1, void_xy_pct = 0.12, void_z_pct = 0.08),
      list(nx = 3, ny = 2, void_xy_pct = 0.12, void_z_pct = 0.08),
      list(nx = 2, ny = 3, void_xy_pct = 0.12, void_z_pct = 0.08)
    )
    if (length(pats) == 0) pats <- list(list(nx = 5, ny = 1, void_xy_pct = 0.12, void_z_pct = 0.08))
    pick <- as.integer(floor(rng$runif(1, min = 0, max = length(pats))) + 1L)
    dims <- pick_refrigerated_case_dims(prod, pick)
    case_L <- dims$case_L
    case_W <- dims$case_W
    case_H <- dims$case_H
    pack_pattern_index <- as.integer(dims$pattern_index)
    chosen_pack_pattern <- paste0(dims$nx, "x", dims$ny)
  }

  cases_per_layer <- compute_cases_per_layer(pallet_L, pallet_W, case_L, case_W, clearance_xy)
  layers <- compute_layers(max_stack_height_in, case_H, clearance_z, fail_if_less_than_one = is_real_run_env())
  cases_per_pallet_raw <- as.numeric(cases_per_layer) * as.numeric(layers)
  cases_per_pallet_draw <- floor(cases_per_pallet_raw * pmin(1, pmax(0, packing_efficiency_draw)))
  if (!is.finite(cases_per_pallet_draw) || cases_per_pallet_draw < 0) cases_per_pallet_draw <- 0

  list(
    unit_weight_lb = unit_weight_lb,
    units_per_case_draw = units_per_case_draw,
    cases_per_pallet_draw = as.numeric(cases_per_pallet_draw),
    cases_per_layer = as.numeric(cases_per_layer),
    layers = as.numeric(layers),
    packing_efficiency_draw = as.numeric(packing_efficiency_draw),
    pallet_tare_lb_draw = pallet_tare_lb_draw,
    case_tare_lb_draw = case_tare_lb_draw,
    pallet_max_stack_height_in = max_stack_height_in,
    derived_case_L_in = as.numeric(case_L),
    derived_case_W_in = as.numeric(case_W),
    derived_case_H_in = as.numeric(case_H),
    chosen_pack_pattern = as.character(chosen_pack_pattern),
    pack_pattern_index = as.integer(pack_pattern_index)
  )
}

compute_units_per_truck <- function(payload_max_lb, pallets_max, unit_weight_lb,
                                    units_per_case_draw = NULL,
                                    cases_per_pallet_draw = NULL,
                                    pallet_tare_lb_draw = NULL,
                                    case_tare_lb_draw = NULL,
                                    cube_units_per_pallet = NULL) {
  scalar_numeric <- function(x) {
    out <- suppressWarnings(as.numeric(x))
    if (length(out) == 0L) return(NA_real_)
    out[[1]]
  }
  payload_max_lb <- as.numeric(payload_max_lb)
  pallets_max <- as.numeric(pallets_max)
  unit_weight_lb <- as.numeric(unit_weight_lb)
  units_per_case_draw <- scalar_numeric(units_per_case_draw)
  cases_per_pallet_draw <- scalar_numeric(cases_per_pallet_draw)
  pallet_tare_lb_draw <- scalar_numeric(pallet_tare_lb_draw)
  case_tare_lb_draw <- scalar_numeric(case_tare_lb_draw)
  cube_units_per_pallet <- scalar_numeric(cube_units_per_pallet)
  legacy_scalar_contract <- !is.finite(units_per_case_draw) &&
    is.finite(cube_units_per_pallet) &&
    !is.finite(cases_per_pallet_draw)

  if (legacy_scalar_contract) {
    units_per_case_draw <- 1
    cases_per_pallet_draw <- cube_units_per_pallet
  }
  if (!is.finite(pallet_tare_lb_draw)) pallet_tare_lb_draw <- 0
  if (!is.finite(case_tare_lb_draw)) case_tare_lb_draw <- 0
  if (!all(is.finite(c(payload_max_lb, pallets_max, unit_weight_lb, units_per_case_draw, cases_per_pallet_draw, pallet_tare_lb_draw, case_tare_lb_draw)))) {
    if (legacy_scalar_contract) return(NA_real_)
    return(list(units_per_truck = NA_real_, cube_limit_units = NA_real_, weight_limit_units = NA_real_, limiting_constraint = NA_character_))
  }

  cube_limit_units <- as.numeric(pallets_max * cases_per_pallet_draw * units_per_case_draw)
  per_unit_mass_lb <- unit_weight_lb + (case_tare_lb_draw / units_per_case_draw)
  weight_limit_units <- floor((payload_max_lb - pallets_max * pallet_tare_lb_draw) / per_unit_mass_lb)
  cube_limit_units <- max(0, floor(cube_limit_units))
  weight_limit_units <- max(0, as.numeric(weight_limit_units))
  units_per_truck <- max(0, floor(min(cube_limit_units, weight_limit_units)))
  limiting_constraint <- if (!is.finite(cube_limit_units) || !is.finite(weight_limit_units)) {
    NA_character_
  } else if (cube_limit_units <= weight_limit_units) {
    "cube"
  } else {
    "weight"
  }

  if (legacy_scalar_contract) {
    return(as.numeric(units_per_truck))
  }

  list(
    units_per_truck = as.numeric(units_per_truck),
    cube_limit_units = as.numeric(cube_limit_units),
    weight_limit_units = as.numeric(weight_limit_units),
    limiting_constraint = as.character(limiting_constraint)
  )
}

resolve_shipment_assignment <- function(capacity_units, units_per_case_draw, assignment_cfg = NULL, exogenous_draws = NULL, rng = NULL) {
  cap <- suppressWarnings(as.numeric(capacity_units))
  upc <- suppressWarnings(as.numeric(units_per_case_draw))
  if (!is.finite(cap) || cap < 0) cap <- NA_real_
  if (!is.finite(upc) || upc <= 0) upc <- NA_real_

  cfg <- assignment_cfg %||% list()
  policy <- tolower(as.character(cfg$policy %||% "full_truckload"))
  if (!policy %in% c("full_truckload", "partial_load", "store_demand_draw")) policy <- "full_truckload"

  exo_assigned_units <- suppressWarnings(as.numeric(exogenous_draws$assigned_units_draw %||% NA_real_))
  exo_assigned_cases <- suppressWarnings(as.numeric(exogenous_draws$assigned_cases_draw %||% NA_real_))
  exo_load_fraction <- suppressWarnings(as.numeric(exogenous_draws$load_fraction_draw %||% NA_real_))

  assigned_units <- NA_real_
  assigned_cases <- NA_real_
  load_fraction <- NA_real_

  if (policy == "full_truckload") {
    assigned_units <- cap
    assigned_cases <- if (is.finite(assigned_units) && is.finite(upc) && upc > 0) floor(assigned_units / upc) else NA_real_
    load_fraction <- 1
  } else if (policy == "partial_load") {
    lf <- if (is.finite(exo_load_fraction)) exo_load_fraction else as.numeric(sim_pick_distribution(cfg$partial_load_fraction, rng = rng))
    if (!is.finite(lf)) lf <- 1
    lf <- min(max(lf, 0), 1)
    load_fraction <- lf
    if (is.finite(cap)) assigned_units <- floor(cap * lf)
    assigned_cases <- if (is.finite(assigned_units) && is.finite(upc) && upc > 0) floor(assigned_units / upc) else NA_real_
  } else if (policy == "store_demand_draw") {
    ac <- if (is.finite(exo_assigned_cases)) exo_assigned_cases else as.numeric(sim_pick_distribution(cfg$assigned_cases, rng = rng))
    if (is.finite(ac)) assigned_cases <- max(0, floor(ac))
    if (is.finite(assigned_cases) && is.finite(upc)) assigned_units <- assigned_cases * upc
    if (is.finite(cap) && is.finite(assigned_units) && cap > 0) load_fraction <- min(1, assigned_units / cap)
  }

  if (is.finite(exo_assigned_units)) {
    assigned_units <- max(0, floor(exo_assigned_units))
    if (is.finite(upc) && upc > 0) assigned_cases <- floor(assigned_units / upc)
    if (is.finite(cap) && cap > 0) load_fraction <- min(1, assigned_units / cap)
  }

  actual_units_loaded <- if (is.finite(cap) && is.finite(assigned_units)) max(0, min(cap, assigned_units)) else NA_real_
  unused_capacity_units <- if (is.finite(cap) && is.finite(actual_units_loaded)) max(0, cap - actual_units_loaded) else NA_real_
  if (is.finite(actual_units_loaded) && is.finite(upc) && upc > 0) assigned_cases <- floor(actual_units_loaded / upc)
  if (is.finite(cap) && cap > 0 && is.finite(actual_units_loaded)) load_fraction <- actual_units_loaded / cap

  list(
    load_assignment_policy = policy,
    assigned_units = as.numeric(assigned_units),
    assigned_cases = as.numeric(assigned_cases),
    actual_units_loaded = as.numeric(actual_units_loaded),
    load_fraction = as.numeric(load_fraction),
    unused_capacity_units = as.numeric(unused_capacity_units)
  )
}

resolve_load_draw <- function(seed, cfg, product_type, exogenous_draws = NULL, load_assignment_policy = NULL) {
  pt <- infer_product_type_from_text(product_type)
  rng <- new_rng(seed + 2L)
  trailer <- sample_trailer_capacity(seed, cfg)
  packaging <- sample_product_packaging(seed + 1L, pt, cfg)

  payload_max_lb_draw <- as.numeric(exogenous_draws$payload_max_lb_draw %||% trailer$payload_max_lb)
  pallets_max <- as.integer(exogenous_draws$pallets_max %||% trailer$pallets_max %||% 26L)
  unit_weight_draw <- if (identical(pt, "dry")) exogenous_draws$unit_weight_lb_dry else exogenous_draws$unit_weight_lb_refrigerated
  unit_weight_lb <- as.numeric(unit_weight_draw %||% packaging$unit_weight_lb)
  units_per_case_draw <- as.numeric((if (identical(pt, "dry")) exogenous_draws$units_per_case_draw_dry else exogenous_draws$units_per_case_draw_refrigerated) %||% exogenous_draws$units_per_case_draw %||% packaging$units_per_case_draw)
  cases_per_pallet_draw <- as.numeric((if (identical(pt, "dry")) exogenous_draws$cases_per_pallet_draw_dry else exogenous_draws$cases_per_pallet_draw_refrigerated) %||% exogenous_draws$cases_per_pallet_draw %||% packaging$cases_per_pallet_draw)
  pallet_tare_lb_draw <- as.numeric(exogenous_draws$pallet_tare_lb_draw %||% packaging$pallet_tare_lb_draw)
  case_tare_lb_draw <- as.numeric((if (identical(pt, "dry")) exogenous_draws$case_tare_lb_draw_dry else exogenous_draws$case_tare_lb_draw_refrigerated) %||% exogenous_draws$case_tare_lb_draw %||% packaging$case_tare_lb_draw)
  packing_efficiency_draw <- as.numeric((if (identical(pt, "dry")) exogenous_draws$packing_efficiency_draw_dry else exogenous_draws$packing_efficiency_draw_refrigerated) %||% exogenous_draws$packing_efficiency_draw %||% packaging$packing_efficiency_draw)
  cases_per_layer <- as.numeric((if (identical(pt, "dry")) exogenous_draws$cases_per_layer_dry else exogenous_draws$cases_per_layer_refrigerated) %||% exogenous_draws$cases_per_layer %||% packaging$cases_per_layer)
  layers <- as.numeric((if (identical(pt, "dry")) exogenous_draws$layers_dry else exogenous_draws$layers_refrigerated) %||% exogenous_draws$layers %||% packaging$layers)
  chosen_pack_pattern <- as.character(exogenous_draws$chosen_pack_pattern_refrigerated %||% exogenous_draws$chosen_pack_pattern %||% packaging$chosen_pack_pattern)
  pack_pattern_index <- as.integer(exogenous_draws$pack_pattern_index_refrigerated %||% exogenous_draws$pack_pattern_index %||% packaging$pack_pattern_index)
  derived_case_L_in <- as.numeric((if (identical(pt, "dry")) exogenous_draws$derived_case_L_in_dry else exogenous_draws$derived_case_L_in_refrigerated) %||% exogenous_draws$derived_case_L_in %||% packaging$derived_case_L_in)
  derived_case_W_in <- as.numeric((if (identical(pt, "dry")) exogenous_draws$derived_case_W_in_dry else exogenous_draws$derived_case_W_in_refrigerated) %||% exogenous_draws$derived_case_W_in %||% packaging$derived_case_W_in)
  derived_case_H_in <- as.numeric((if (identical(pt, "dry")) exogenous_draws$derived_case_H_in_dry else exogenous_draws$derived_case_H_in_refrigerated) %||% exogenous_draws$derived_case_H_in %||% packaging$derived_case_H_in)

  limits <- compute_units_per_truck(
    payload_max_lb = payload_max_lb_draw,
    pallets_max = pallets_max,
    unit_weight_lb = unit_weight_lb,
    units_per_case_draw = units_per_case_draw,
    cases_per_pallet_draw = cases_per_pallet_draw,
    pallet_tare_lb_draw = pallet_tare_lb_draw,
    case_tare_lb_draw = case_tare_lb_draw
  )

  if (is_real_run_env()) {
    if (!is.finite(units_per_case_draw) || !is.finite(cases_per_pallet_draw)) {
      stop("REAL_RUN requires finite units_per_case_draw and cases_per_pallet_draw.")
    }
    if (!is.finite(cases_per_layer) || !is.finite(layers) || cases_per_layer < 1 || layers < 1) {
      stop("REAL_RUN requires cases_per_layer >=1 and layers >=1.")
    }
  }

  units <- as.numeric(limits$units_per_truck)
  per_unit_lb <- if (is.finite(units_per_case_draw) && units_per_case_draw > 0) unit_weight_lb + (case_tare_lb_draw / units_per_case_draw) else NA_real_
  payload_used_lb <- if (is.finite(units) && is.finite(per_unit_lb)) (units * per_unit_lb) + (pallets_max * pallet_tare_lb_draw) else NA_real_
  payload_utilization_pct <- if (is.finite(payload_used_lb) && is.finite(payload_max_lb_draw) && payload_max_lb_draw > 0) 100 * payload_used_lb / payload_max_lb_draw else NA_real_
  cube_utilization_pct <- if (is.finite(units) && is.finite(limits$cube_limit_units) && limits$cube_limit_units > 0) 100 * units / limits$cube_limit_units else NA_real_
  shipment_cfg <- cfg$load_model$shipment_assignment %||% list()
  if (!is.null(load_assignment_policy) && nzchar(as.character(load_assignment_policy))) {
    shipment_cfg$policy <- as.character(load_assignment_policy)
  }
  assigned <- resolve_shipment_assignment(
    capacity_units = units,
    units_per_case_draw = units_per_case_draw,
    assignment_cfg = shipment_cfg,
    exogenous_draws = exogenous_draws,
    rng = rng
  )
  actual_units_loaded <- as.numeric(assigned$actual_units_loaded %||% units)
  product_mass_lb_actual <- if (is.finite(actual_units_loaded) && is.finite(unit_weight_lb)) actual_units_loaded * unit_weight_lb else NA_real_
  cases_per_truck_capacity <- if (is.finite(units) && is.finite(units_per_case_draw) && units_per_case_draw > 0) units / units_per_case_draw else NA_real_

  list(
    payload_max_lb_draw = payload_max_lb_draw,
    pallets_max = pallets_max,
    unit_weight_lb = unit_weight_lb,
    units_per_case_draw = units_per_case_draw,
    cases_per_pallet_draw = cases_per_pallet_draw,
    cases_per_layer = cases_per_layer,
    layers = layers,
    packing_efficiency_draw = packing_efficiency_draw,
    pallet_tare_lb_draw = pallet_tare_lb_draw,
    case_tare_lb_draw = case_tare_lb_draw,
    cube_limit_units = as.numeric(limits$cube_limit_units),
    weight_limit_units = as.numeric(limits$weight_limit_units),
    limiting_constraint = as.character(limits$limiting_constraint),
    units_per_truck_capacity = as.numeric(units),
    cases_per_truck_capacity = as.numeric(cases_per_truck_capacity),
    assigned_units = as.numeric(assigned$assigned_units),
    assigned_cases = as.numeric(assigned$assigned_cases),
    actual_units_loaded = as.numeric(actual_units_loaded),
    load_fraction = as.numeric(assigned$load_fraction),
    unused_capacity_units = as.numeric(assigned$unused_capacity_units),
    load_assignment_policy = as.character(assigned$load_assignment_policy %||% NA_character_),
    units_per_truck = as.numeric(actual_units_loaded),
    payload_utilization_pct = as.numeric(payload_utilization_pct),
    cube_utilization_pct = as.numeric(cube_utilization_pct),
    product_mass_lb_per_truck = as.numeric(product_mass_lb_actual),
    pallet_max_stack_height_in = as.numeric(packaging$pallet_max_stack_height_in %||% NA_real_),
    chosen_pack_pattern = chosen_pack_pattern,
    pack_pattern_index = pack_pattern_index,
    derived_case_L_in = derived_case_L_in,
    derived_case_W_in = derived_case_W_in,
    derived_case_H_in = derived_case_H_in
  )
}
