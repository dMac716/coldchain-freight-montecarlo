# Load and packaging model helpers.

infer_product_type_from_text <- function(x, default = "refrigerated") {
  s <- tolower(as.character(x %||% ""))
  if (grepl("dry", s, fixed = TRUE)) return("dry")
  if (grepl("refriger", s, fixed = TRUE)) return("refrigerated")
  tolower(as.character(default %||% "refrigerated"))
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

sample_product_packaging <- function(seed, product_type, test_kit) {
  rng <- new_rng(seed)
  lm <- test_kit$load_model %||% list()
  prod <- lm$products[[tolower(as.character(product_type %||% "refrigerated"))]] %||% list()
  unit_weight_lb <- as.numeric(prod$unit_weight_lb %||% NA_real_)

  if (identical(tolower(as.character(product_type %||% "")), "dry")) {
    bpp <- as.numeric(sim_pick_distribution(prod$bags_per_pallet, rng = rng))
    return(list(
      unit_weight_lb = unit_weight_lb,
      cube_units_per_pallet = bpp,
      bags_per_pallet = bpp,
      cases_per_pallet = NA_real_,
      packs_per_case = NA_real_
    ))
  }

  cpp <- as.numeric(sim_pick_distribution(prod$cases_per_pallet, rng = rng))
  ppc <- as.numeric(prod$packs_per_case %||% NA_real_)
  list(
    unit_weight_lb = unit_weight_lb,
    cube_units_per_pallet = cpp * ppc,
    bags_per_pallet = NA_real_,
    cases_per_pallet = cpp,
    packs_per_case = ppc
  )
}

compute_units_per_truck <- function(payload_max_lb, pallets_max, unit_weight_lb, cube_units_per_pallet) {
  payload_max_lb <- as.numeric(payload_max_lb)
  pallets_max <- as.numeric(pallets_max)
  unit_weight_lb <- as.numeric(unit_weight_lb)
  cube_units_per_pallet <- as.numeric(cube_units_per_pallet)
  if (!all(is.finite(c(payload_max_lb, pallets_max, unit_weight_lb, cube_units_per_pallet)))) return(NA_real_)
  if (payload_max_lb <= 0 || pallets_max <= 0 || unit_weight_lb <= 0 || cube_units_per_pallet <= 0) return(NA_real_)
  weight_limit_units <- payload_max_lb / unit_weight_lb
  cube_limit_units <- pallets_max * cube_units_per_pallet
  floor(min(weight_limit_units, cube_limit_units))
}

resolve_load_draw <- function(seed, cfg, product_type, exogenous_draws = NULL) {
  trailer <- sample_trailer_capacity(seed, cfg)
  packaging <- sample_product_packaging(seed + 1L, product_type, cfg)

  payload_max_lb_draw <- if (!is.null(exogenous_draws) && is.finite(as.numeric(exogenous_draws$payload_max_lb_draw %||% NA_real_))) {
    as.numeric(exogenous_draws$payload_max_lb_draw)
  } else {
    as.numeric(trailer$payload_max_lb)
  }
  pallets_max <- as.integer(exogenous_draws$pallets_max %||% trailer$pallets_max %||% 26L)
  unit_weight_draw <- if (identical(tolower(as.character(product_type %||% "")), "dry")) {
    exogenous_draws$unit_weight_lb_dry %||% exogenous_draws$unit_weight_lb
  } else {
    exogenous_draws$unit_weight_lb_refrigerated %||% exogenous_draws$unit_weight_lb
  }
  unit_weight_lb <- if (!is.null(exogenous_draws) && is.finite(as.numeric(unit_weight_draw %||% NA_real_))) {
    as.numeric(unit_weight_draw)
  } else {
    as.numeric(packaging$unit_weight_lb)
  }
  cube_units_per_pallet <- if (!is.null(exogenous_draws) && is.finite(as.numeric(exogenous_draws$cube_units_per_pallet %||% NA_real_))) {
    as.numeric(exogenous_draws$cube_units_per_pallet)
  } else {
    as.numeric(packaging$cube_units_per_pallet)
  }

  units <- compute_units_per_truck(payload_max_lb_draw, pallets_max, unit_weight_lb, cube_units_per_pallet)
  list(
    payload_max_lb_draw = payload_max_lb_draw,
    pallets_max = pallets_max,
    unit_weight_lb = unit_weight_lb,
    cube_units_per_pallet = cube_units_per_pallet,
    units_per_truck = as.numeric(units),
    product_mass_lb_per_truck = if (is.finite(units) && is.finite(unit_weight_lb)) units * unit_weight_lb else NA_real_,
    bags_per_pallet = as.numeric(exogenous_draws$bags_per_pallet %||% packaging$bags_per_pallet),
    cases_per_pallet = as.numeric(exogenous_draws$cases_per_pallet %||% packaging$cases_per_pallet),
    packs_per_case = as.numeric(exogenous_draws$packs_per_case %||% packaging$packs_per_case)
  )
}
