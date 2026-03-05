# Run bundle creation for collaboration publishing.

safe_git <- function(args) {
  out <- tryCatch(system2("git", args = args, stdout = TRUE, stderr = FALSE), error = function(e) "")
  if (length(out) == 0) return("")
  as.character(out[[1]])
}

git_metadata <- function() {
  sha <- safe_git(c("rev-parse", "HEAD"))
  branch <- safe_git(c("rev-parse", "--abbrev-ref", "HEAD"))
  dirty <- NA
  st <- tryCatch(system2("git", args = c("status", "--porcelain"), stdout = TRUE, stderr = FALSE), error = function(e) character())
  if (length(st) >= 0) dirty <- length(st) > 0
  list(git_sha = sha, git_branch = branch, repo_dirty = isTRUE(dirty))
}

run_status_from_sim <- function(sim) {
  if (!is.null(sim$metadata) && isTRUE(sim$metadata$plan_soc_violation)) return("plan_soc_violation")
  if (!is.null(sim$event_log) && nrow(sim$event_log) > 0 && any(sim$event_log$event_type == "ROUTE_COMPLETE")) return("ok")
  "ok"
}

run_summary_row <- function(sim, context) {
  ss <- sim$sim_state
  if (is.null(ss) || nrow(ss) == 0) return(data.frame())
  last <- ss[nrow(ss), , drop = FALSE]
  sched <- sim$metadata$schedule %||% list()
  ld <- sim$metadata$load %||% list()
  nutr <- sim$metadata$nutrition %||% list()
  product_type <- as.character(context$product_type %||% NA_character_)
  origin_network <- as.character(context$origin_network %||% NA_character_)
  kcal_delivered <- as.numeric(context$kcal_delivered %||% NA_real_)
  protein_kg_delivered <- as.numeric(context$protein_kg_delivered %||% NA_real_)
  co2_total <- as.numeric(last$co2_kg_cum[[1]])
  co2_upstream <- as.numeric(context$co2_kg_upstream %||% NA_real_)
  co2_full <- if (is.finite(co2_upstream)) co2_total + co2_upstream else NA_real_
  transport_cost_usd <- as.numeric(context$transport_cost_usd %||% context$transport_cost_total %||% NA_real_)
  base_price_per_kcal <- as.numeric(context$base_price_per_kcal %||% NA_real_)
  baseline_dry_price_per_kcal <- as.numeric(context$baseline_dry_price_per_kcal %||% NA_real_)
  kcal_delivered <- if (is.finite(kcal_delivered)) pmax(kcal_delivered, 1e-9) else NA_real_
  protein_kg_delivered <- if (is.finite(protein_kg_delivered)) pmax(protein_kg_delivered, 1e-9) else NA_real_
  transport_cost_per_kcal <- if (is.finite(transport_cost_usd) && is.finite(kcal_delivered) && kcal_delivered > 0) transport_cost_usd / kcal_delivered else NA_real_
  delivered_price_per_kcal <- if (is.finite(base_price_per_kcal) && is.finite(transport_cost_per_kcal)) base_price_per_kcal + transport_cost_per_kcal else NA_real_
  delivery_time_min <- as.numeric(sched$delivery_time_min %||% NA_real_)
  driver_driving_min <- as.numeric(sched$driver_driving_min %||% NA_real_)
  driver_on_duty_min <- as.numeric(sched$driver_on_duty_min %||% NA_real_)
  driver_off_duty_min <- as.numeric(sched$driver_off_duty_min %||% NA_real_)
  time_charging_min <- as.numeric(sched$time_charging_min %||% NA_real_)
  time_refuel_min <- as.numeric(sched$time_refuel_min %||% NA_real_)
  time_load_unload_min <- as.numeric(sched$time_load_unload_min %||% NA_real_)
  time_traffic_delay_min <- as.numeric(sched$time_traffic_delay_min %||% NA_real_)
  num_break_30min <- as.integer(sched$num_break_30min %||% NA_integer_)
  num_rest_10hr <- as.integer(sched$num_rest_10hr %||% NA_integer_)
  sanity <- compute_load_sanity_flags(ld, run_id = as.character(context$run_id %||% ""))
  data.frame(
    run_id = as.character(context$run_id),
    pair_id = as.character(context$pair_id %||% NA_character_),
    scenario = as.character(context$scenario %||% NA_character_),
    traffic_mode = as.character(context$traffic_mode %||% NA_character_),
    product_type = product_type,
    origin_network = origin_network,
    route_id = as.character(context$route_id %||% NA_character_),
    route_plan_id = as.character(context$route_plan_id %||% NA_character_),
    leg = as.character(context$trip_leg %||% NA_character_),
    distance_miles = as.numeric(last$distance_miles_cum[[1]]),
    duration_minutes = as.numeric(as.numeric(difftime(as.POSIXct(last$t[[1]], tz = "UTC"), as.POSIXct(ss$t[[1]], tz = "UTC"), units = "mins"))),
    co2_kg_total = co2_total,
    co2_kg_total_transport = co2_total,
    co2_kg_upstream = co2_upstream,
    co2_kg_full = co2_full,
    co2_kg_propulsion = NA_real_,
    co2_kg_tru = NA_real_,
    kcal_delivered = kcal_delivered,
    mass_required_for_fu_kg = as.numeric(context$mass_required_for_fu_kg %||% NA_real_),
    protein_kg_delivered = protein_kg_delivered,
    protein_per_1000kcal = if (is.finite(protein_kg_delivered) && is.finite(kcal_delivered) && kcal_delivered > 0) (protein_kg_delivered * 1000) / kcal_delivered else NA_real_,
    co2_per_1000kcal = if (is.finite(kcal_delivered) && kcal_delivered > 0) co2_total / (kcal_delivered / 1000) else NA_real_,
    co2_per_kg_protein = if (is.finite(protein_kg_delivered) && protein_kg_delivered > 0) co2_total / protein_kg_delivered else NA_real_,
    co2_g_per_g_protein = if (is.finite(protein_kg_delivered) && protein_kg_delivered > 0) (co2_total * 1000) / (protein_kg_delivered * 1000) else NA_real_,
    co2_full_per_1000kcal = if (is.finite(co2_full) && is.finite(kcal_delivered) && kcal_delivered > 0) co2_full / (kcal_delivered / 1000) else NA_real_,
    co2_full_per_kg_protein = if (is.finite(co2_full) && is.finite(protein_kg_delivered) && protein_kg_delivered > 0) co2_full / protein_kg_delivered else NA_real_,
    co2_full_g_per_g_protein = if (is.finite(co2_full) && is.finite(protein_kg_delivered) && protein_kg_delivered > 0) (co2_full * 1000) / (protein_kg_delivered * 1000) else NA_real_,
    transport_cost_usd = transport_cost_usd,
    transport_cost_total = transport_cost_usd,
    transport_cost_per_1000kcal = if (is.finite(transport_cost_usd) && is.finite(kcal_delivered) && kcal_delivered > 0) transport_cost_usd / (kcal_delivered / 1000) else NA_real_,
    transport_cost_per_kcal = transport_cost_per_kcal,
    transport_cost_per_kg_protein = if (is.finite(transport_cost_usd) && is.finite(protein_kg_delivered) && protein_kg_delivered > 0) transport_cost_usd / protein_kg_delivered else NA_real_,
    base_price_per_kcal = base_price_per_kcal,
    delivered_price_per_kcal = delivered_price_per_kcal,
    price_index = if (is.finite(delivered_price_per_kcal) && is.finite(base_price_per_kcal) && base_price_per_kcal > 0) delivered_price_per_kcal / base_price_per_kcal else NA_real_,
    price_index_vs_dry_baseline = if (is.finite(delivered_price_per_kcal) && is.finite(baseline_dry_price_per_kcal) && baseline_dry_price_per_kcal > 0) delivered_price_per_kcal / baseline_dry_price_per_kcal else NA_real_,
    energy_kwh_propulsion = as.numeric(last$propulsion_kwh_cum[[1]]),
    energy_kwh_tru = as.numeric(last$tru_kwh_cum[[1]]),
    diesel_gal_propulsion = as.numeric(last$diesel_gal_cum[[1]]),
    diesel_gal_tru = as.numeric(last$tru_gal_cum[[1]]),
    charge_stops = as.integer(last$charge_count[[1]]),
    refuel_stops = as.integer(last$refuel_count[[1]]),
    delay_minutes = as.numeric(last$delay_minutes_cum[[1]]),
    driving_time_h = if ("driving_time_h_cum" %in% names(last)) as.numeric(last$driving_time_h_cum[[1]]) else NA_real_,
    traffic_delay_time_h = if ("traffic_delay_h_cum" %in% names(last)) as.numeric(last$traffic_delay_h_cum[[1]]) else NA_real_,
    charging_or_refueling_time_h = if ("service_time_h_cum" %in% names(last)) as.numeric(last$service_time_h_cum[[1]]) else NA_real_,
    rest_time_h = if ("rest_time_h_cum" %in% names(last)) as.numeric(last$rest_time_h_cum[[1]]) else NA_real_,
    trip_duration_total_h = if ("trip_duration_h_cum" %in% names(last)) as.numeric(last$trip_duration_h_cum[[1]]) else NA_real_,
    payload_max_lb_draw = as.numeric(ld$payload_max_lb_draw %||% NA_real_),
    units_per_truck = as.numeric(ld$units_per_truck %||% NA_real_),
    cases_per_pallet_draw = as.numeric(ld$cases_per_pallet_draw %||% NA_real_),
    units_per_case_draw = as.numeric(ld$units_per_case_draw %||% NA_real_),
    cube_limit_units = as.numeric(ld$cube_limit_units %||% NA_real_),
    weight_limit_units = as.numeric(ld$weight_limit_units %||% NA_real_),
    limiting_constraint = as.character(ld$limiting_constraint %||% NA_character_),
    payload_utilization_pct = as.numeric(ld$payload_utilization_pct %||% NA_real_),
    cube_utilization_pct = as.numeric(ld$cube_utilization_pct %||% NA_real_),
    cases_per_layer = as.numeric(ld$cases_per_layer %||% NA_real_),
    layers = as.numeric(ld$layers %||% NA_real_),
    packing_efficiency_draw = as.numeric(ld$packing_efficiency_draw %||% NA_real_),
    chosen_pack_pattern = as.character(ld$chosen_pack_pattern %||% NA_character_),
    pack_pattern_index = as.integer(ld$pack_pattern_index %||% NA_integer_),
    derived_case_L_in = as.numeric(ld$derived_case_L_in %||% NA_real_),
    derived_case_W_in = as.numeric(ld$derived_case_W_in %||% NA_real_),
    derived_case_H_in = as.numeric(ld$derived_case_H_in %||% NA_real_),
    product_mass_lb_per_truck = as.numeric(ld$product_mass_lb_per_truck %||% NA_real_),
    kcal_per_truck = as.numeric(ld$kcal_per_truck %||% NA_real_),
    protein_kg_per_truck = as.numeric(ld$protein_kg_per_truck %||% NA_real_),
    kcal_per_kg_product = as.numeric(nutr$kcal_per_kg_product %||% NA_real_),
    protein_g_per_kg_product = as.numeric(nutr$protein_g_per_kg_product %||% NA_real_),
    delivery_time_min = delivery_time_min,
    driver_driving_min = driver_driving_min,
    driver_on_duty_min = driver_on_duty_min,
    driver_off_duty_min = driver_off_duty_min,
    time_charging_min = time_charging_min,
    time_refuel_min = time_refuel_min,
    time_load_unload_min = time_load_unload_min,
    time_traffic_delay_min = time_traffic_delay_min,
    num_break_30min = num_break_30min,
    num_rest_10hr = num_rest_10hr,
    sanity_flag_low_cube_util = as.integer(sanity$sanity_flag_low_cube_util),
    sanity_flag_high_cube_util = as.integer(sanity$sanity_flag_high_cube_util),
    sanity_flag_unrealistic_case_dims = as.integer(sanity$sanity_flag_unrealistic_case_dims),
    truckloads_per_1e6_kcal = if (is.finite(as.numeric(ld$kcal_per_truck %||% NA_real_)) && as.numeric(ld$kcal_per_truck) > 0) 1e6 / as.numeric(ld$kcal_per_truck) else NA_real_,
    truckloads_per_1000kg_product = if (is.finite(as.numeric(ld$product_mass_lb_per_truck %||% NA_real_)) && as.numeric(ld$product_mass_lb_per_truck) > 0) {
      1000 / (as.numeric(ld$product_mass_lb_per_truck) * 0.45359237)
    } else {
      NA_real_
    },
    trucker_hours_per_1000kcal = if (is.finite(driver_on_duty_min) && is.finite(kcal_delivered) && kcal_delivered > 0) {
      (driver_on_duty_min / 60) / (kcal_delivered / 1000)
    } else {
      NA_real_
    },
    fuel_type_outbound = if (isTRUE(identical(context$trip_leg, "outbound"))) as.character(last$fuel_type_label[[1]]) else NA_character_,
    fuel_type_return = if (isTRUE(identical(context$trip_leg, "return"))) as.character(last$fuel_type_label[[1]]) else NA_character_,
    stringsAsFactors = FALSE
  )
}

infer_product_type_from_context <- function(context, cfg_resolved) {
  pt <- as.character(context$product_type %||% "")
  if (nzchar(pt)) return(tolower(pt))
  sc <- tolower(as.character(context$scenario %||% ""))
  if (grepl("dry", sc, fixed = TRUE)) return("dry")
  if (grepl("refriger", sc, fixed = TRUE)) return("refrigerated")
  cg <- tolower(as.character(cfg_resolved$cargo$product_category %||% ""))
  if (grepl("dry", cg, fixed = TRUE)) return("dry")
  "refrigerated"
}

pick_distribution_local <- function(spec, rng = NULL) {
  if (is.null(spec)) return(NA_real_)
  if (is.numeric(spec) && length(spec) == 1) return(as.numeric(spec))
  d <- spec$distribution %||% spec
  typ <- tolower(as.character(d$type %||% ""))
  u <- if (!is.null(rng) && !is.null(rng$runif)) rng$runif(1) else stats::runif(1)
  if (typ == "triangular") {
    a <- as.numeric(d$min); c <- as.numeric(d$mode); b <- as.numeric(d$max)
    if (!all(is.finite(c(a, b, c))) || a > c || c > b) return(NA_real_)
    if (a == b) return(a)
    fc <- (c - a) / (b - a)
    if (u < fc) return(a + sqrt(u * (b - a) * (c - a)))
    return(b - sqrt((1 - u) * (b - a) * (b - c)))
  }
  if (typ == "uniform") {
    a <- as.numeric(d$min); b <- as.numeric(d$max)
    if (!all(is.finite(c(a, b))) || b < a) return(NA_real_)
    return(a + u * (b - a))
  }
  as.numeric(d$mode %||% d$value %||% NA_real_)
}

sample_nutrition_profile <- function(cfg_resolved, product_type, seed = 123) {
  # Deterministic per-run draw for nutrition uncertainty.
  set.seed(as.integer(seed))
  rng <- new.env(parent = emptyenv())
  rng$runif <- function(...) stats::runif(...)

  p <- tolower(as.character(product_type %||% "refrigerated"))
  nsec <- cfg_resolved$nutrition[[p]]
  if (is.null(nsec)) {
    return(list(
      kcal_per_kg = suppressWarnings(as.numeric(cfg_resolved$cargo$kcal_per_kg$distribution$mode %||% NA_real_)),
      protein_g_per_kg = NA_real_
    ))
  }
  list(
    kcal_per_kg = pick_distribution_local(nsec$kcal_per_kg, rng = rng),
    protein_g_per_kg = pick_distribution_local(nsec$protein_g_per_kg, rng = rng)
  )
}

derive_delivered_nutrition <- function(sim, cfg_resolved, context) {
  ss <- sim$sim_state
  if (is.null(ss) || nrow(ss) == 0) return(list(kcal_delivered = NA_real_, protein_kg_delivered = NA_real_, shipment_mass_kg = NA_real_, product_type = NA_character_))
  ld <- sim$metadata$load %||% list()
  payload_lb <- if ("payload_lb" %in% names(ss)) suppressWarnings(as.numeric(ss$payload_lb[[nrow(ss)]])) else NA_real_
  if (is.finite(as.numeric(ld$product_mass_lb_per_truck %||% NA_real_))) {
    payload_lb <- as.numeric(ld$product_mass_lb_per_truck)
  }
  payload_kg <- if (is.finite(payload_lb)) payload_lb * 0.45359237 else NA_real_
  product_type <- infer_product_type_from_context(context, cfg_resolved)
  fu_kcal <- as.numeric(cfg_resolved$cargo$functional_unit_kcal %||% 1000)
  food_inputs <- read_food_inputs("data")
  prof <- resolve_food_profile(product_type, food_inputs = food_inputs, seed = as.integer(context$seed %||% 123))
  if (is.null(prof) || !is.finite(prof$kcal_per_kg_product)) {
    prof <- sample_nutrition_profile(cfg_resolved, product_type = product_type, seed = as.integer(context$seed %||% 123) + 7919L)
    prof <- list(
      kcal_per_kg_product = prof$kcal_per_kg,
      protein_g_per_kg_product = prof$protein_g_per_kg,
      kgco2_per_kg_product = NA_real_
    )
  }
  kcal <- if (is.finite(payload_kg) && is.finite(prof$kcal_per_kg_product)) payload_kg * prof$kcal_per_kg_product else NA_real_
  protein_kg <- if (is.finite(payload_kg) && is.finite(prof$protein_g_per_kg_product)) payload_kg * prof$protein_g_per_kg_product / 1000 else NA_real_
  fu_mass <- mass_required_for_fu_kg(product_type, fu_kcal = fu_kcal, food_inputs = food_inputs, seed = as.integer(context$seed %||% 123))
  list(
    kcal_delivered = kcal,
    protein_kg_delivered = protein_kg,
    shipment_mass_kg = payload_kg,
    mass_required_for_fu_kg = fu_mass,
    kgco2_per_kg_product = as.numeric(prof$kgco2_per_kg_product %||% NA_real_),
    ingredient_rows = prof$ingredient_rows %||% data.frame(),
    product_type = product_type
  )
}

derive_transport_cost <- function(sim, cfg_resolved) {
  ss <- sim$sim_state
  if (is.null(ss) || nrow(ss) == 0) return(NA_real_)
  last <- ss[nrow(ss), , drop = FALSE]
  t0 <- as.POSIXct(ss$t[[1]], tz = "UTC")
  t1 <- as.POSIXct(last$t[[1]], tz = "UTC")
  duration_h <- as.numeric(difftime(t1, t0, units = "hours"))

  diesel_price <- suppressWarnings(as.numeric(cfg_resolved$costs$diesel_price_per_gal %||% NA_real_))
  elec_price <- suppressWarnings(as.numeric(cfg_resolved$costs$electricity_price_per_kwh %||% NA_real_))
  driver_cost_h <- suppressWarnings(as.numeric(cfg_resolved$costs$driver_cost_per_hour %||% NA_real_))

  diesel_gal_total <- suppressWarnings(as.numeric(last$diesel_gal_cum[[1]]) + as.numeric(last$tru_gal_cum[[1]]))
  elec_kwh_total <- suppressWarnings(as.numeric(last$propulsion_kwh_cum[[1]]) + as.numeric(last$tru_kwh_cum[[1]]))

  fuel_cost <- if (is.finite(diesel_gal_total) && is.finite(diesel_price)) diesel_gal_total * diesel_price else 0
  elec_cost <- if (is.finite(elec_kwh_total) && is.finite(elec_price)) elec_kwh_total * elec_price else 0
  labor_cost <- if (is.finite(duration_h) && is.finite(driver_cost_h)) duration_h * driver_cost_h else 0
  total <- fuel_cost + elec_cost + labor_cost
  if (!is.finite(total)) NA_real_ else total
}

base_price_per_kcal_for_product <- function(cfg_resolved, product_type) {
  p <- tolower(as.character(product_type %||% "refrigerated"))
  # Preferred: explicit costs.base_price_per_kcal.<product>
  x <- suppressWarnings(as.numeric(cfg_resolved$costs$base_price_per_kcal[[p]] %||% NA_real_))
  if (is.finite(x)) return(x)
  # Fallback: derive from costs.base_price_per_kg / nutrition kcal_per_kg
  price_kg <- suppressWarnings(as.numeric(cfg_resolved$costs$base_price_per_kg[[p]] %||% NA_real_))
  kcal_kg <- suppressWarnings(as.numeric(cfg_resolved$nutrition[[p]]$kcal_per_kg$distribution$mode %||% NA_real_))
  if (is.finite(price_kg) && is.finite(kcal_kg) && kcal_kg > 0) return(price_kg / kcal_kg)
  NA_real_
}

normalize_lci_key <- function(x) {
  gsub("[^a-z0-9]+", "", tolower(trimws(as.character(x %||% ""))))
}

parse_numeric_text <- function(x) {
  y <- gsub(",", "", as.character(x))
  suppressWarnings(as.numeric(y))
}

lci_detect_header_row <- function(mat) {
  nr <- nrow(mat)
  if (nr == 0) return(NA_integer_)
  for (i in seq_len(min(nr, 50L))) {
    row_vals <- tolower(as.character(unlist(mat[i, , drop = TRUE])))
    has_amount <- any(grepl("amount|value|quantity", row_vals))
    has_units <- any(grepl("unit", row_vals))
    has_name <- any(grepl("flow|name|substance", row_vals))
    if (has_amount && has_units && has_name) return(i)
  }
  NA_integer_
}

lci_pick_col <- function(nm, pattern) {
  idx <- which(grepl(pattern, nm))
  if (length(idx) == 0) return(NA_integer_)
  idx[[1]]
}

lci_gwp_for_flow <- function(flow_name, gwp_cfg) {
  f <- tolower(as.character(flow_name %||% ""))
  if (grepl("methane|\\bch4\\b", f)) return(as.numeric(gwp_cfg$ch4 %||% NA_real_))
  if (grepl("nitrous oxide|dinitrogen monoxide|\\bn2o\\b", f)) return(as.numeric(gwp_cfg$n2o %||% NA_real_))
  if (grepl("carbon dioxide|\\bco2\\b", f)) {
    if (grepl("biotic|biogenic", f)) return(as.numeric(gwp_cfg$co2_biogenic %||% 0))
    return(as.numeric(gwp_cfg$co2_fossil %||% 1))
  }
  NA_real_
}

lci_sheet_intensity_co2e <- function(path, sheet_name, gwp_cfg) {
  raw <- readxl::read_excel(path, sheet = sheet_name, col_names = FALSE)
  if (nrow(raw) == 0 || ncol(raw) == 0) return(NA_real_)
  h <- lci_detect_header_row(raw)
  if (!is.finite(h)) return(NA_real_)
  if (h >= nrow(raw)) return(NA_real_)

  headers <- trimws(as.character(unlist(raw[h, , drop = TRUE])))
  headers[headers == ""] <- paste0("col_", seq_along(headers))[headers == ""]
  dat <- raw[(h + 1):nrow(raw), , drop = FALSE]
  if (nrow(dat) == 0) return(NA_real_)
  names(dat) <- headers
  nm <- tolower(names(dat))
  flow_i <- lci_pick_col(nm, "flow|name|substance")
  amt_i <- lci_pick_col(nm, "amount|value|quantity")
  unit_i <- lci_pick_col(nm, "unit")
  if (!is.finite(flow_i) || !is.finite(amt_i)) return(NA_real_)

  flow <- as.character(dat[[flow_i]])
  amt <- parse_numeric_text(dat[[amt_i]])
  keep <- is.finite(amt) & !is.na(flow) & nzchar(trimws(flow))
  if (is.finite(unit_i)) {
    u <- tolower(trimws(as.character(dat[[unit_i]])))
    keep <- keep & grepl("\\bkg\\b", u)
  }
  if (!any(keep)) return(0)
  flow <- flow[keep]
  amt <- amt[keep]
  gwp <- vapply(flow, function(x) lci_gwp_for_flow(x, gwp_cfg), numeric(1))
  valid <- is.finite(gwp)
  if (!any(valid)) return(0)
  sum(amt[valid] * gwp[valid], na.rm = TRUE)
}

lci_read_intensity_table <- function(cfg_resolved) {
  lci_cfg <- cfg_resolved$lci
  enabled <- isTRUE(as.logical(lci_cfg$enabled %||% FALSE))
  if (!enabled) return(data.frame())
  wb <- as.character(lci_cfg$lci_workbook_path %||% "LCI.xlsx")
  if (!file.exists(wb)) stop("LCI enabled but workbook not found: ", wb)
  if (!requireNamespace("readxl", quietly = TRUE)) {
    stop("LCI enabled but readxl package is not installed")
  }

  gwp_cfg <- lci_cfg$gwp100 %||% list(co2_fossil = 1, co2_biogenic = 0, ch4 = 27.2, n2o = 273)
  cache_key <- paste(
    normalizePath(wb, winslash = "/", mustWork = TRUE),
    as.character(gwp_cfg$co2_fossil %||% 1),
    as.character(gwp_cfg$co2_biogenic %||% 0),
    as.character(gwp_cfg$ch4 %||% 27.2),
    as.character(gwp_cfg$n2o %||% 273),
    sep = "|"
  )
  cache <- getOption("coldchain.lci_intensity_cache", default = list())
  if (!is.null(cache[[cache_key]])) return(cache[[cache_key]])

  sheets <- readxl::excel_sheets(wb)
  rows <- lapply(sheets, function(s) {
    data.frame(
      sheet_name = as.character(s),
      process_key = normalize_lci_key(s),
      co2e_kg_per_unit = as.numeric(lci_sheet_intensity_co2e(wb, s, gwp_cfg)),
      stringsAsFactors = FALSE
    )
  })
  out <- do.call(rbind, rows)
  out <- lci_apply_process_key_map(out, cfg_resolved)
  cache[[cache_key]] <- out
  options(coldchain.lci_intensity_cache = cache)
  out
}

lci_read_process_key_map <- function(cfg_resolved) {
  lci_cfg <- cfg_resolved$lci %||% list()
  map_path <- as.character(lci_cfg$process_key_map_path %||% file.path("data", "inputs", "lci_process_key_map.csv"))
  if (!nzchar(map_path) || !file.exists(map_path)) return(data.frame())
  m <- tryCatch(utils::read.csv(map_path, stringsAsFactors = FALSE), error = function(e) data.frame())
  if (nrow(m) == 0) return(data.frame())
  need <- c("process_key", "sheet_name")
  if (!all(need %in% names(m))) return(data.frame())
  m$process_key <- normalize_lci_key(m$process_key)
  m$sheet_name_norm <- normalize_lci_key(m$sheet_name)
  m <- m[nzchar(m$process_key) & nzchar(m$sheet_name_norm), c("process_key", "sheet_name_norm"), drop = FALSE]
  if (nrow(m) == 0) return(data.frame())
  unique(m)
}

lci_apply_process_key_map <- function(intensity_tbl, cfg_resolved) {
  if (is.null(intensity_tbl) || nrow(intensity_tbl) == 0) return(intensity_tbl)
  mp <- lci_read_process_key_map(cfg_resolved)
  if (nrow(mp) == 0) return(intensity_tbl)
  d <- intensity_tbl
  d$sheet_name_norm <- normalize_lci_key(d$sheet_name)
  j <- merge(mp, d[, c("sheet_name_norm", "co2e_kg_per_unit"), drop = FALSE], by = "sheet_name_norm", all.x = TRUE)
  j <- j[is.finite(j$co2e_kg_per_unit), c("process_key", "co2e_kg_per_unit"), drop = FALSE]
  if (nrow(j) == 0) return(intensity_tbl)
  mapped <- stats::aggregate(co2e_kg_per_unit ~ process_key, data = j, FUN = function(x) x[[1]])
  mapped$sheet_name <- paste0("mapped:", mapped$process_key)
  mapped <- mapped[, c("sheet_name", "process_key", "co2e_kg_per_unit"), drop = FALSE]
  base <- intensity_tbl[, c("sheet_name", "process_key", "co2e_kg_per_unit"), drop = FALSE]
  base <- base[!base$process_key %in% mapped$process_key, , drop = FALSE]
  rbind(base, mapped)
}

derive_upstream_lci <- function(cfg_resolved, product_type, shipment_mass_kg) {
  lci_cfg <- cfg_resolved$lci
  enabled <- isTRUE(as.logical(lci_cfg$enabled %||% FALSE))
  if (!enabled || !is.finite(shipment_mass_kg)) return(list(co2_kg_upstream = NA_real_, upstream_co2e_per_kg_product = NA_real_))

  intensity_tbl <- lci_read_intensity_table(cfg_resolved)
  if (nrow(intensity_tbl) == 0) return(list(co2_kg_upstream = NA_real_, upstream_co2e_per_kg_product = NA_real_))

  comp <- lci_cfg$product_composition[[tolower(as.character(product_type %||% ""))]]
  if (is.null(comp) || length(comp) == 0) return(list(co2_kg_upstream = NA_real_, upstream_co2e_per_kg_product = NA_real_))

  comp_df <- data.frame(
    process_key = normalize_lci_key(names(comp)),
    share = suppressWarnings(as.numeric(unname(unlist(comp)))),
    stringsAsFactors = FALSE
  )
  comp_df <- comp_df[is.finite(comp_df$share), , drop = FALSE]
  if (nrow(comp_df) == 0) return(list(co2_kg_upstream = NA_real_, upstream_co2e_per_kg_product = NA_real_))

  m <- merge(comp_df, intensity_tbl[, c("process_key", "co2e_kg_per_unit"), drop = FALSE], by = "process_key", all.x = TRUE)
  m$co2e_kg_per_unit[!is.finite(m$co2e_kg_per_unit)] <- 0
  upstream_per_kg <- sum(m$share * m$co2e_kg_per_unit, na.rm = TRUE)
  list(
    co2_kg_upstream = upstream_per_kg * shipment_mass_kg,
    upstream_co2e_per_kg_product = upstream_per_kg
  )
}

artifact_manifest <- function(paths_named) {
  nm <- names(paths_named)
  if (length(nm) == 0) return(data.frame())
  rows <- lapply(seq_along(paths_named), function(i) {
    p <- as.character(paths_named[[i]])
    exists <- file.exists(p)
    list(
      key = as.character(nm[[i]]),
      path = p,
      exists = isTRUE(exists),
      sha256 = if (isTRUE(exists)) sha256_file(p) else NA_character_,
      row_count = if (isTRUE(exists)) nrow(utils::read.csv(p, stringsAsFactors = FALSE)) else NA_integer_
    )
  })
  do.call(rbind.data.frame, c(rows, stringsAsFactors = FALSE))
}

inputs_hash_from_artifacts <- function(artifacts_df) {
  if (is.null(artifacts_df) || nrow(artifacts_df) == 0) return(NA_character_)
  key <- paste(
    artifacts_df$key,
    artifacts_df$sha256,
    artifacts_df$row_count,
    sep = "=",
    collapse = "|"
  )
  sha256_text(key)
}

warn_packaging_mass_tbd_once <- function(run_id, product_type) {
  p <- file.path("data", "inputs_local", "products.csv")
  if (!file.exists(p)) return(invisible(NULL))
  d <- tryCatch(utils::read.csv(p, stringsAsFactors = FALSE), error = function(e) data.frame())
  if (nrow(d) == 0 || !"status" %in% names(d)) return(invisible(NULL))
  status <- toupper(as.character(d$status))
  pt_col <- if ("product_type" %in% names(d)) tolower(as.character(d$product_type)) else rep("", nrow(d))
  pt <- tolower(as.character(product_type %||% ""))
  has_tbd <- any(status == "PACKAGING_MASS_TBD" & (pt_col == pt | !nzchar(pt_col)), na.rm = TRUE)
  if (!has_tbd) return(invisible(NULL))
  key <- paste0("coldchain.packaging_warned.", as.character(run_id))
  if (isTRUE(getOption(key, FALSE))) return(invisible(NULL))
  message("WARN: PACKAGING_MASS_TBD present in products.csv; continuing in demo mode.")
  do.call(options, setNames(list(TRUE), key))
  invisible(NULL)
}

enforce_real_run_requirements <- function(sim) {
  real_run <- Sys.getenv("REAL_RUN", unset = "0")
  is_real <- tolower(trimws(real_run)) %in% c("1", "true", "yes", "y")
  if (!is_real) return(invisible(NULL))
  ld <- sim$metadata$load %||% list()
  nutr <- sim$metadata$nutrition %||% list()
  if (!is.finite(as.numeric(ld$unit_weight_lb %||% NA_real_))) {
    stop("REAL_RUN requires finite unit_weight_lb in load model.")
  }
  if (!is.finite(as.numeric(ld$units_per_case_draw %||% NA_real_))) {
    stop("REAL_RUN requires finite units_per_case_draw in load model.")
  }
  if (!is.finite(as.numeric(ld$cases_per_pallet_draw %||% NA_real_))) {
    stop("REAL_RUN requires finite cases_per_pallet_draw in load model.")
  }
  if (!is.finite(as.numeric(ld$cube_limit_units %||% NA_real_)) || as.numeric(ld$cube_limit_units %||% 0) < 1) {
    stop("REAL_RUN requires cube_limit_units >= 1.")
  }
  if (!is.finite(as.numeric(nutr$kcal_per_kg_product %||% NA_real_))) {
    stop("REAL_RUN requires finite kcal_per_kg_product.")
  }
  invisible(NULL)
}

compute_load_sanity_flags <- function(ld, run_id = "") {
  cube_util <- as.numeric(ld$cube_utilization_pct %||% NA_real_)
  payload_util <- as.numeric(ld$payload_utilization_pct %||% NA_real_)
  # Accept either fraction [0,1] or percent [0,100].
  cube_util_frac <- if (is.finite(cube_util) && cube_util > 1.5) cube_util / 100 else cube_util
  payload_util_frac <- if (is.finite(payload_util) && payload_util > 1.5) payload_util / 100 else payload_util

  case_dims <- c(
    as.numeric(ld$derived_case_L_in %||% NA_real_),
    as.numeric(ld$derived_case_W_in %||% NA_real_),
    as.numeric(ld$derived_case_H_in %||% NA_real_)
  )
  cases_per_pallet_draw <- as.numeric(ld$cases_per_pallet_draw %||% NA_real_)
  flags <- list(
    sanity_flag_low_cube_util = as.integer(is.finite(cube_util_frac) && cube_util_frac < 0.25),
    sanity_flag_high_cube_util = as.integer((is.finite(cube_util_frac) && cube_util_frac > 1.05) || (is.finite(payload_util_frac) && payload_util_frac > 1.05) || (is.finite(payload_util_frac) && payload_util_frac < 0.10)),
    sanity_flag_unrealistic_case_dims = as.integer(any(is.finite(case_dims) & case_dims > 60))
  )

  if (is_real_run_env()) {
    if ((is.finite(cases_per_pallet_draw) && (cases_per_pallet_draw < 10 || cases_per_pallet_draw > 120)) ||
      isTRUE(flags$sanity_flag_high_cube_util == 1L) ||
      isTRUE(flags$sanity_flag_unrealistic_case_dims == 1L)) {
      stop("REAL_RUN load realism sanity check failed for run_id=", as.character(run_id))
    }
  } else {
    if (is.finite(cases_per_pallet_draw) && (cases_per_pallet_draw < 10 || cases_per_pallet_draw > 120)) {
      message("WARN: cases_per_pallet_draw out of demo sanity bounds [10,120] for run_id=", as.character(run_id))
    }
    if (isTRUE(flags$sanity_flag_low_cube_util == 1L) || isTRUE(flags$sanity_flag_high_cube_util == 1L)) {
      message("WARN: cube/payload utilization out of demo sanity bounds for run_id=", as.character(run_id))
    }
    if (isTRUE(flags$sanity_flag_unrealistic_case_dims == 1L)) {
      message("WARN: refrigerated derived case dimensions exceed plausible bounds for run_id=", as.character(run_id))
    }
  }
  flags
}

write_run_bundle <- function(
    sim,
    context,
    cfg_resolved = list(),
    artifact_paths = NULL,
    tracks_path = NULL,
    bundle_root = "outputs/run_bundle") {
  if (is.null(context$run_id) || !nzchar(context$run_id)) stop("context$run_id is required")
  run_id <- as.character(context$run_id)
  bundle_dir <- file.path(bundle_root, run_id)
  dir.create(bundle_dir, recursive = TRUE, showWarnings = FALSE)

  if (is.null(artifact_paths)) {
    artifact_paths <- c(
      routes_geometry = "data/derived/routes_facility_to_petco.csv",
      bev_route_plans = "data/derived/bev_route_plans.csv",
      ev_stations = "data/derived/ev_charging_stations_corridor.csv",
      od_cache = "data/derived/google_routes_od_cache.csv"
    )
  }

  g <- git_metadata()
  artifacts_df <- artifact_manifest(artifact_paths)
  inputs_hash <- inputs_hash_from_artifacts(artifacts_df)
  status <- run_status_from_sim(sim)
  enforce_real_run_requirements(sim)
  warn_packaging_mass_tbd_once(run_id, context$product_type %||% sim$metadata$product_type)
  nd <- derive_delivered_nutrition(sim, cfg_resolved, context)
  context$product_type <- as.character(context$product_type %||% nd$product_type)
  context$kcal_delivered <- as.numeric(context$kcal_delivered %||% nd$kcal_delivered)
  context$protein_kg_delivered <- as.numeric(context$protein_kg_delivered %||% nd$protein_kg_delivered)
  context$shipment_mass_kg <- as.numeric(context$shipment_mass_kg %||% nd$shipment_mass_kg)
  context$mass_required_for_fu_kg <- as.numeric(context$mass_required_for_fu_kg %||% nd$mass_required_for_fu_kg)
  context$co2_kg_upstream <- as.numeric(
    context$co2_kg_upstream %||%
      if (is.finite(nd$kgco2_per_kg_product) && is.finite(context$shipment_mass_kg)) nd$kgco2_per_kg_product * context$shipment_mass_kg else NA_real_
  )
  context$transport_cost_usd <- as.numeric(context$transport_cost_usd %||% context$transport_cost_total %||% derive_transport_cost(sim, cfg_resolved))
  context$base_price_per_kcal <- as.numeric(context$base_price_per_kcal %||% base_price_per_kcal_for_product(cfg_resolved, context$product_type))
  context$baseline_dry_price_per_kcal <- as.numeric(context$baseline_dry_price_per_kcal %||% base_price_per_kcal_for_product(cfg_resolved, "dry"))
  lci <- derive_upstream_lci(cfg_resolved, context$product_type, context$shipment_mass_kg)
  context$co2_kg_upstream <- as.numeric(context$co2_kg_upstream %||% lci$co2_kg_upstream)
  context$upstream_co2e_per_kg_product <- as.numeric(context$upstream_co2e_per_kg_product %||% lci$upstream_co2e_per_kg_product)
  summary_row <- run_summary_row(sim, context)

  ingredient_summary <- data.frame()
  if (!is.null(nd$ingredient_rows) && nrow(nd$ingredient_rows) > 0 && is.finite(context$mass_required_for_fu_kg)) {
    ir <- nd$ingredient_rows
    kgco2_col <- if ("kgco2_per_kg" %in% names(ir)) suppressWarnings(as.numeric(ir$kgco2_per_kg)) else rep(0, nrow(ir))
    kgco2_col[!is.finite(kgco2_col)] <- 0
    ir$kg_ingredient_per_1000kcal <- as.numeric(ir$mass_fraction) * as.numeric(context$mass_required_for_fu_kg)
    ir$upstream_kgco2_per_1000kcal <- ir$kg_ingredient_per_1000kcal * kgco2_col
    ingredient_summary <- data.frame(
      run_id = run_id,
      product_type = as.character(context$product_type %||% NA_character_),
      ingredient_raw = as.character(ir$ingredient_raw),
      lci_key = as.character(ir$lci_key),
      mass_fraction = as.numeric(ir$mass_fraction),
      kg_ingredient_per_1000kcal = as.numeric(ir$kg_ingredient_per_1000kcal),
      upstream_kgco2_per_1000kcal = as.numeric(ir$upstream_kgco2_per_1000kcal),
      confidence = as.character(ir$confidence %||% NA_character_),
      stringsAsFactors = FALSE
    )
  }

  runs_obj <- list(
    run_id = run_id,
    created_at_utc = as.character(format(Sys.time(), tz = "UTC", usetz = TRUE)),
    runner = Sys.getenv("USER", unset = ""),
    git_sha = g$git_sha,
    git_branch = g$git_branch,
    repo_dirty = g$repo_dirty,
    status = status,
    scenario = context$scenario %||% NA_character_,
    product_type = context$product_type %||% NA_character_,
    origin_network = context$origin_network %||% NA_character_,
    route_id = context$route_id %||% NA_character_,
    route_plan_id = context$route_plan_id %||% NA_character_,
    seed = as.integer(context$seed %||% NA_integer_),
    mc_draws = as.integer(context$mc_draws %||% 1L),
    gcs_prefix = NA_character_,
    inputs_hash = inputs_hash
  )

  params_obj <- list(
    run_id = run_id,
    pair_id = context$pair_id %||% NA_character_,
    scenario = context$scenario %||% NA_character_,
    traffic_mode = context$traffic_mode %||% NA_character_,
    product_type = context$product_type %||% NA_character_,
    origin_network = context$origin_network %||% NA_character_,
    facility_id = context$facility_id %||% NA_character_,
    powertrain = context$powertrain %||% NA_character_,
    trip_leg = context$trip_leg %||% NA_character_,
    seed = as.integer(context$seed %||% NA_integer_),
    mc_draws = as.integer(context$mc_draws %||% 1L),
    route_id = context$route_id %||% NA_character_,
    route_plan_id = context$route_plan_id %||% NA_character_,
    config = cfg_resolved
  )

  runs_path <- file.path(bundle_dir, "runs.json")
  summaries_path <- file.path(bundle_dir, "summaries.csv")
  ingredients_path <- file.path(bundle_dir, "upstream_ingredients.csv")
  events_path <- file.path(bundle_dir, "events.csv")
  params_path <- file.path(bundle_dir, "params.json")
  artifacts_path <- file.path(bundle_dir, "artifacts.json")
  tracks_gz_path <- file.path(bundle_dir, "tracks.csv.gz")

  jsonlite::write_json(runs_obj, runs_path, pretty = TRUE, auto_unbox = TRUE, null = "null")
  utils::write.csv(summary_row, summaries_path, row.names = FALSE)
  if (nrow(ingredient_summary) > 0) {
    utils::write.csv(ingredient_summary, ingredients_path, row.names = FALSE)
  }
  utils::write.csv(sim$event_log, events_path, row.names = FALSE)
  jsonlite::write_json(params_obj, params_path, pretty = TRUE, auto_unbox = TRUE, null = "null")
  jsonlite::write_json(artifacts_df, artifacts_path, pretty = TRUE, auto_unbox = TRUE, dataframe = "rows", null = "null")

  if (!is.null(tracks_path) && file.exists(tracks_path)) {
    con_in <- file(tracks_path, open = "rb")
    con_out <- gzfile(tracks_gz_path, open = "wb")
    on.exit(try(close(con_in), silent = TRUE), add = TRUE)
    on.exit(try(close(con_out), silent = TRUE), add = TRUE)
    repeat {
      buf <- readBin(con_in, what = raw(), n = 1024 * 1024)
      if (length(buf) == 0) break
      writeBin(buf, con_out)
    }
  }

  list(
    bundle_dir = bundle_dir,
    runs_path = runs_path,
    summaries_path = summaries_path,
    ingredients_path = if (file.exists(ingredients_path)) ingredients_path else NA_character_,
    events_path = events_path,
    params_path = params_path,
    artifacts_path = artifacts_path,
    tracks_gz_path = if (file.exists(tracks_gz_path)) tracks_gz_path else NA_character_
  )
}
