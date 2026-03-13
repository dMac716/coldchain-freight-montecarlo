read_inputs_local <- function(dir = "data/inputs_local") {
  read_csv_required <- function(path) {
    if (!file.exists(path)) stop("Missing required input file: ", path)
    utils::read.csv(path, stringsAsFactors = FALSE)
  }
  read_csv_optional <- function(path) {
    if (!file.exists(path)) return(data.frame(stringsAsFactors = FALSE))
    info <- file.info(path)
    if (!is.finite(info$size) || info$size <= 1) return(data.frame(stringsAsFactors = FALSE))
    out <- tryCatch(
      utils::read.csv(path, stringsAsFactors = FALSE),
      error = function(e) data.frame(stringsAsFactors = FALSE)
    )
    out
  }

  derived_file <- file.path(dirname(dir), "derived", "faf_distance_distributions.csv")
  routes_file <- file.path(dirname(dir), "derived", "google_routes_distance_distributions.csv")
  dist_base <- read_csv_optional(derived_file)
  dist_routes <- read_csv_optional(routes_file)
  dist_all <- merge_distance_distributions(dist_base, dist_routes)

  list(
    functional_unit = read_csv_optional(file.path(dir, "functional_unit.csv")),
    facilities = read_csv_optional(file.path(dir, "facilities.csv")),
    retail_nodes = read_csv_optional(file.path(dir, "retail_nodes.csv")),
    products = read_csv_required(file.path(dir, "products.csv")),
    scenarios = read_csv_required(file.path(dir, "scenarios.csv")),
    histogram_config = read_csv_required(file.path(dir, "histogram_config.csv")),
    assumptions = read_csv_required(file.path(dir, "assumptions_used.csv")),
    factors = read_csv_optional(file.path(dir, "factors.csv")),
    emissions_factors = read_csv_optional(file.path(dir, "emissions_factors.csv")),
    sampling_priors = read_csv_optional(file.path(dir, "sampling_priors.csv")),
    scenario_matrix = read_csv_optional(file.path(dir, "scenario_matrix.csv")),
    distance_distributions = dist_all,
    grid_ci = read_csv_optional(file.path(dir, "grid_ci.csv")),
    road_distance_fixed = read_csv_optional(file.path(dirname(dir), "derived", "road_distance_facility_to_retail.csv")),
    routes_facility_to_petco = read_csv_optional(file.path(dirname(dir), "derived", "routes_facility_to_petco.csv")),
    route_elevation_profiles = read_csv_optional(file.path(dirname(dir), "derived", "route_elevation_profiles.csv")),
    ev_charging_stations_corridor = read_csv_optional(file.path(dirname(dir), "derived", "ev_charging_stations_corridor.csv")),
    bev_route_plans = read_csv_optional(file.path(dirname(dir), "derived", "bev_route_plans.csv"))
  )
}

merge_distance_distributions <- function(base_df, routes_df) {
  if (nrow(base_df) == 0) return(base_df)
  if (nrow(routes_df) == 0) return(base_df)
  if (!all(c("distance_distribution_id", "status") %in% names(routes_df))) return(base_df)

  routes_ok <- subset(routes_df, status == "OK")
  if (nrow(routes_ok) == 0) return(base_df)
  keys <- intersect(routes_ok$distance_distribution_id, base_df$distance_distribution_id)
  if (length(keys) == 0) return(base_df)

  out <- base_df
  for (id in keys) {
    src <- routes_ok[routes_ok$distance_distribution_id == id, , drop = FALSE][1, , drop = FALSE]
    dst_idx <- which(out$distance_distribution_id == id)
    for (nm in intersect(names(out), names(src))) {
      out[dst_idx, nm] <- src[[nm]][[1]]
    }
  }
  out
}

read_sources_manifest <- function(path = "sources/sources_manifest.csv") {
  if (!file.exists(path)) stop("Sources manifest not found: ", path)
  utils::read.csv(path, stringsAsFactors = FALSE)
}

source_id_from_filename <- function(filename, manifest_df = NULL) {
  if (is.null(manifest_df)) manifest_df <- read_sources_manifest()
  hits <- manifest_df$source_id[manifest_df$filename == filename]
  if (length(hits) == 0) {
    stop("No source_id found for filename: ", filename)
  }
  if (length(hits) > 1) {
    stop("Multiple source_id entries found for filename: ", filename)
  }
  hits[[1]]
}

attach_source_ref <- function(value, filename, source_page, manifest_df = NULL, notes = NA_character_) {
  sid <- source_id_from_filename(filename, manifest_df = manifest_df)
  data.frame(
    value = value,
    source_id = sid,
    source_page = source_page,
    notes = notes,
    stringsAsFactors = FALSE
  )
}

canonicalize_object_keys <- function(x) {
  if (is.data.frame(x)) {
    x <- as.list(x)
  }

  if (!is.list(x)) {
    return(x)
  }

  nms <- names(x)
  if (is.null(nms)) {
    return(lapply(x, canonicalize_object_keys))
  }

  ord <- order(nms)
  out <- x[ord]
  out <- lapply(out, canonicalize_object_keys)
  names(out) <- nms[ord]
  out
}

artifact_canonical_payload <- function(artifact_obj) {
  out <- artifact_obj
  out$integrity <- NULL
  canonicalize_object_keys(out)
}

artifact_canonical_json <- function(artifact_obj) {
  canonical <- artifact_canonical_payload(artifact_obj)
  jsonlite::toJSON(
    canonical,
    auto_unbox = TRUE,
    null = "null",
    digits = NA,
    pretty = FALSE
  )
}

artifact_canonical_sha256 <- function(artifact_obj) {
  sha256_text(artifact_canonical_json(artifact_obj))
}

artifact_canonical_sha256_from_file <- function(path_json) {
  artifact_obj <- jsonlite::fromJSON(path_json, simplifyVector = FALSE)
  artifact_canonical_sha256(artifact_obj)
}

resolve_inputs <- function(scenario_row, product_row) {
  list(
    FU_kcal = scenario_row$FU_kcal,
    kcal_per_kg_dry = product_row$kcal_per_kg_dry,
    kcal_per_kg_reefer = product_row$kcal_per_kg_reefer,
    pkg_kg_per_kg_dry = product_row$pkg_kg_per_kg_dry,
    pkg_kg_per_kg_reefer = product_row$pkg_kg_per_kg_reefer,
    distance_miles = scenario_row$distance_miles,
    truck_g_per_ton_mile = scenario_row$truck_g_per_ton_mile,
    reefer_extra_g_per_ton_mile = scenario_row$reefer_extra_g_per_ton_mile,
    util_dry = scenario_row$util_dry,
    util_reefer = scenario_row$util_reefer
  )
}

wildcard_match <- function(value, pattern) {
  if (is.na(pattern) || !nzchar(pattern)) return(FALSE)
  if (pattern == "*") return(TRUE)
  esc <- gsub("([][{}()+?.^$|\\\\])", "\\\\\\\\1", pattern)
  rx <- paste0("^", gsub("\\*", ".*", esc), "$")
  grepl(rx, value, ignore.case = TRUE)
}

prior_point_estimate <- function(spec) {
  if (is.null(spec) || is.null(spec$distribution)) return(NA_real_)
  dist <- tolower(spec$distribution)
  if (dist == "fixed") return(spec$p1)
  if (dist == "triangular") return(spec$p2)
  if (dist == "normal") return(spec$p1)
  if (dist == "lognormal") return(exp(spec$p1))
  NA_real_
}

select_variant_rows <- function(inputs, selector) {
  matrix <- inputs$scenario_matrix
  if (nrow(matrix) == 0) {
    stop("scenario_matrix.csv is required for locked-scope runs.")
  }

  if (selector %in% matrix$variant_id) {
    out <- subset(matrix, variant_id == selector)
    return(out[order(out$variant_id), , drop = FALSE])
  }

  if (selector %in% matrix$scenario_id) {
    out <- subset(matrix, scenario_id == selector)
    if (nrow(out) == 0) stop("No variants found for scenario_id: ", selector)
    return(out[order(out$variant_id), , drop = FALSE])
  }

  stop("Selector not found as variant_id or scenario_id: ", selector)
}

resolve_sampling_priors <- function(priors_df, variant_row) {
  if (nrow(priors_df) == 0) return(data.frame(stringsAsFactors = FALSE))
  required <- c("param_id", "distribution", "p1", "p2", "p3", "applies_to")
  if (!all(required %in% names(priors_df))) {
    stop("sampling_priors.csv missing required columns: ", paste(setdiff(required, names(priors_df)), collapse = ", "))
  }

  keys <- unique(c(
    variant_row$variant_id,
    variant_row$scenario_id,
    toupper(variant_row$powertrain),
    toupper(variant_row$refrigeration_mode),
    toupper(variant_row$trailer_type),
    paste0(toupper(variant_row$powertrain), "_CASE"),
    variant_row$run_group,
    "*"
  ))

  hit <- vapply(priors_df$applies_to, function(pat) any(vapply(keys, wildcard_match, logical(1), pattern = pat)), logical(1))
  priors <- priors_df[hit, , drop = FALSE]
  if (nrow(priors) == 0) return(priors)

  priors$.priority <- vapply(priors$applies_to, function(pat) {
    if (identical(pat, variant_row$variant_id)) return(5)
    if (wildcard_match(variant_row$variant_id, pat)) return(4)
    if (wildcard_match(variant_row$scenario_id, pat)) return(3)
    if (wildcard_match(toupper(variant_row$powertrain), pat) || wildcard_match(paste0(toupper(variant_row$powertrain), "_CASE"), pat)) return(2)
    if (pat == "*") return(1)
    0
  }, numeric(1))
  priors <- priors[order(priors$param_id, -priors$.priority), , drop = FALSE]
  priors <- priors[!duplicated(priors$param_id), , drop = FALSE]
  priors$.priority <- NULL
  priors
}

build_sampling_from_priors <- function(priors_df, variant_row = NULL) {
  if (nrow(priors_df) == 0) return(list())
  if (!is.null(variant_row)) {
    priors_df <- resolve_sampling_priors(priors_df, variant_row)
  }
  if (nrow(priors_df) == 0) return(list())

  sampling <- list()
  for (i in seq_len(nrow(priors_df))) {
    row <- priors_df[i, , drop = FALSE]
    dist <- tolower(trimws(row$distribution[[1]]))
    if (!dist %in% c("triangular", "fixed", "normal", "lognormal")) next

    sampling[[row$param_id[[1]]]] <- list(
      distribution = dist,
      p1 = as.numeric(row$p1[[1]]),
      p2 = suppressWarnings(as.numeric(row$p2[[1]])),
      p3 = suppressWarnings(as.numeric(row$p3[[1]])),
      source_id = if ("source_id" %in% names(row)) row$source_id[[1]] else NA_character_,
      source_page = if ("source_page" %in% names(row)) row$source_page[[1]] else NA_character_,
      status = if ("status" %in% names(row)) row$status[[1]] else "OK"
    )
  }
  sampling
}

derive_sampling_from_distance <- function(distance_row) {
  if (nrow(distance_row) == 0) return(NULL)
  if (!"distance_model" %in% names(distance_row)) return(NULL)
  model <- distance_row$distance_model[[1]]
  p05 <- suppressWarnings(as.numeric(distance_row$p05_miles[[1]]))
  p50 <- suppressWarnings(as.numeric(distance_row$p50_miles[[1]]))
  p95 <- suppressWarnings(as.numeric(distance_row$p95_miles[[1]]))
  if (!is.finite(p50)) return(NULL)

  if (identical(model, "triangular_fit") && all(is.finite(c(p05, p50, p95))) && p05 < p95) {
    return(list(distribution = "triangular", p1 = p05, p2 = p50, p3 = p95))
  }
  list(distribution = "fixed", p1 = p50, p2 = NA_real_, p3 = NA_real_)
}

scale_sampling_spec <- function(spec, factor) {
  if (is.null(spec) || !is.finite(factor) || factor <= 0) return(spec)
  out <- spec
  for (nm in c("p1", "p2", "p3")) {
    if (!is.null(out[[nm]]) && is.finite(out[[nm]])) out[[nm]] <- out[[nm]] * factor
  }
  out
}

infer_variant_dimensions <- function(variant_row, scenario_row) {
  trailer_type <- as.character(variant_row$trailer_type[[1]])
  refrigeration_mode <- as.character(variant_row$refrigeration_mode[[1]])
  powertrain <- as.character(variant_row$powertrain[[1]])

  product_mode <- if ("product_mode" %in% names(variant_row) &&
                      nzchar(as.character(variant_row$product_mode[[1]]))) {
    normalize_product_mode(variant_row$product_mode[[1]])
  } else if (identical(trailer_type, "refrigerated") || !identical(refrigeration_mode, "none")) {
    "REFRIGERATED"
  } else {
    "DRY"
  }

  spatial_structure <- if ("spatial_structure" %in% names(variant_row) &&
                           nzchar(as.character(variant_row$spatial_structure[[1]]))) {
    normalize_spatial_structure(variant_row$spatial_structure[[1]])
  } else if ("spatial_structure" %in% names(scenario_row) &&
             nzchar(as.character(scenario_row$spatial_structure[[1]]))) {
    normalize_spatial_structure(scenario_row$spatial_structure[[1]])
  } else {
    normalize_spatial_structure(scenario_row$scenario_id[[1]])
  }

  powertrain_config <- if ("powertrain_config" %in% names(variant_row) &&
                           nzchar(as.character(variant_row$powertrain_config[[1]]))) {
    normalize_powertrain_config(variant_row$powertrain_config[[1]])
  } else if (identical(powertrain, "bev")) {
    "BEV_TRU_ELECTRIC"
  } else {
    "DIESEL_TRU_DIESEL"
  }

  list(
    product_mode = product_mode,
    spatial_structure = spatial_structure,
    powertrain_config = powertrain_config
  )
}

resolve_variant_inputs <- function(inputs, variant_row, mode = "SMOKE_LOCAL") {
  scenarios <- inputs$scenarios
  products <- inputs$products
  ef <- inputs$emissions_factors

  scenario_row <- subset(scenarios, scenario_id == variant_row$scenario_id)
  if (nrow(scenario_row) == 0) stop("scenario_id missing in scenarios.csv: ", variant_row$scenario_id)
  scenario_row <- scenario_row[1, , drop = FALSE]
  dims <- infer_variant_dimensions(variant_row, scenario_row)

  product_row <- products
  if ("product_mode" %in% names(product_row)) {
    product_row <- subset(product_row, toupper(product_mode) == dims$product_mode)
  } else {
    preservation_needed <- if (identical(dims$product_mode, "REFRIGERATED")) "refrigerated" else "dry"
    product_row <- subset(product_row, preservation == preservation_needed)
  }
  if (nrow(product_row) == 0) stop("No product row found for product_mode=", dims$product_mode)
  product_row <- product_row[order(product_row$product_id), , drop = FALSE][1, , drop = FALSE]

  factor_row <- subset(
    ef,
    powertrain == variant_row$powertrain &
      trailer_type == variant_row$trailer_type &
      refrigeration_mode == variant_row$refrigeration_mode
  )
  if (nrow(factor_row) > 0) factor_row <- factor_row[1, , drop = FALSE]

  dry_factor_row <- subset(
    ef,
    powertrain == variant_row$powertrain &
      trailer_type == "dry_van" &
      refrigeration_mode == "none"
  )
  if (nrow(dry_factor_row) > 0) dry_factor_row <- dry_factor_row[1, , drop = FALSE]

  dist_row <- subset(inputs$distance_distributions, distance_distribution_id == scenario_row$distance_distribution_id)
  if (nrow(dist_row) > 0) dist_row <- dist_row[1, , drop = FALSE]

  scale_col <- if ("regionalized_distance_scale" %in% names(scenario_row)) "regionalized_distance_scale" else if ("distance_scale" %in% names(scenario_row)) "distance_scale" else NA_character_
  distance_scale <- if (!is.na(scale_col)) suppressWarnings(as.numeric(scenario_row[[scale_col]][[1]])) else NA_real_
  if (!is.finite(distance_scale) || distance_scale <= 0) distance_scale <- 1

  priors <- build_sampling_from_priors(inputs$sampling_priors, variant_row = variant_row)
  dist_sampling <- derive_sampling_from_distance(dist_row)
  if (!is.null(dist_sampling)) priors$distance_miles <- dist_sampling
  priors$distance_miles <- scale_sampling_spec(priors$distance_miles, distance_scale)

  prior_value <- function(param, fallback = NA_real_) {
    if (param %in% names(priors)) {
      v <- prior_point_estimate(priors[[param]])
      if (is.finite(v)) return(v)
    }
    fallback
  }
  prior_value_any <- function(params, fallback = NA_real_) {
    for (p in params) {
      v <- prior_value(p, NA_real_)
      if (is.finite(v)) return(v)
    }
    fallback
  }
  row_value <- function(row, col, fallback = NA_real_) {
    if (nrow(row) == 0 || !(col %in% names(row))) return(fallback)
    v <- suppressWarnings(as.numeric(row[[col]][[1]]))
    if (is.finite(v)) return(v)
    fallback
  }

  fu_id <- if ("fu_id" %in% names(scenario_row)) as.character(scenario_row$fu_id[[1]]) else "FU_1000_KCAL"
  fu_default <- suppressWarnings(as.numeric(scenario_row$FU_kcal[[1]]))
  if (!is.finite(fu_default) || fu_default <= 0) fu_default <- 1000
  FU_kcal <- prior_value("FU_kcal", resolve_fu_kcal(inputs$functional_unit, fu_id = fu_id, fallback = fu_default))

  dry_row <- if ("product_mode" %in% names(products)) subset(products, toupper(product_mode) == "DRY") else subset(products, preservation == "dry")
  reefer_row <- if ("product_mode" %in% names(products)) subset(products, toupper(product_mode) == "REFRIGERATED") else subset(products, preservation == "refrigerated")
  if (nrow(dry_row) > 0) dry_row <- dry_row[1, , drop = FALSE]
  if (nrow(reefer_row) > 0) reefer_row <- reefer_row[1, , drop = FALSE]
  dry_kcal <- row_value(dry_row, "kcal_per_kg", 3675)
  reefer_kcal <- row_value(reefer_row, "kcal_per_kg", 2375)
  dry_pkg <- row_value(dry_row, "packaging_mass_frac", 0.05)
  reefer_pkg <- row_value(reefer_row, "packaging_mass_frac", 0.12)

  distance_mode <- if ("distance_mode" %in% names(variant_row) && nzchar(as.character(variant_row$distance_mode[[1]]))) {
    toupper(trimws(as.character(variant_row$distance_mode[[1]])))
  } else {
    toupper(Sys.getenv("DISTANCE_MODE", "FAF_DISTRIBUTION"))
  }

  facility_id_for_mode <- if (dims$product_mode == "REFRIGERATED") "FACILITY_REFRIG_ENNIS" else "FACILITY_DRY_TOPEKA"
  retail_fixed <- "PETCO_DAVIS_COVELL"
  fixed_row <- data.frame(stringsAsFactors = FALSE)
  if (nrow(inputs$road_distance_fixed) > 0) {
    fixed_row <- subset(inputs$road_distance_fixed, facility_id == facility_id_for_mode & retail_id == retail_fixed)
    if (nrow(fixed_row) > 0) fixed_row <- fixed_row[1, , drop = FALSE]
  }
  if (distance_mode %in% c("ROAD_NETWORK_FIXED_DEST", "ROAD_NETWORK_PHYSICS") && nrow(fixed_row) == 0) {
    stop("Missing cached road distance row for facility_id=", facility_id_for_mode, " retail_id=", retail_fixed)
  }

  distance_base <- if (nrow(dist_row) > 0) suppressWarnings(as.numeric(dist_row$p50_miles[[1]])) else NA_real_
  if (distance_mode %in% c("ROAD_NETWORK_FIXED_DEST", "ROAD_NETWORK_PHYSICS") && nrow(fixed_row) > 0) {
    distance_base <- suppressWarnings(as.numeric(fixed_row$distance_km[[1]]) * 0.621371)
  }
  distance_miles <- prior_value("distance_miles", distance_base * distance_scale)
  if (!is.finite(distance_miles)) distance_miles <- 1200 * distance_scale

  util_dry <- prior_value("util_dry", 1)
  util_reefer <- prior_value("util_reefer", 1)

  payload <- prior_value("default_payload_tons", row_value(factor_row, "default_payload_tons", row_value(dry_factor_row, "default_payload_tons", 16.35)))
  if (!is.finite(payload) || payload <= 0) payload <- 16.35

  grid_case <- if ("grid_case" %in% names(variant_row)) variant_row$grid_case[[1]] else scenario_row$grid_case[[1]]
  grid_ci_row <- data.frame(stringsAsFactors = FALSE)
  if (nrow(inputs$grid_ci) > 0 && !is.null(grid_case) && !is.na(grid_case) && nzchar(grid_case) && grid_case != "NA") {
    grid_ci_row <- inputs$grid_ci[inputs$grid_ci$grid_case == grid_case, , drop = FALSE]
    if (nrow(grid_ci_row) > 0) grid_ci_row <- grid_ci_row[1, , drop = FALSE]
  }
  grid_ci <- prior_value_any(
    c("grid_co2_g_per_kwh"),
    if (nrow(grid_ci_row) > 0) suppressWarnings(as.numeric(grid_ci_row$co2_g_per_kwh[[1]])) else suppressWarnings(as.numeric(scenario_row$grid_co2_g_per_kwh[[1]]))
  )
  if (!is.finite(grid_ci)) grid_ci <- row_value(factor_row, "grid_co2_g_per_kwh", 380)

  kwh_tract <- prior_value_any(c("bev_kwh_per_mile_tract", "kwh_per_mile_tract"), row_value(factor_row, "kwh_per_mile_tract", NA_real_))
  kwh_tru <- prior_value_any(c("etru_kwh_per_mile", "kwh_per_mile_tru"), row_value(factor_row, "kwh_per_mile_tru", NA_real_))
  if (!is.finite(kwh_tru)) {
    tru_kw <- prior_value_any(c("etru_kw_draw", "tru_power_kw"), NA_real_)
    speed <- prior_value_any(c("linehaul_avg_speed_mph", "linehaul_speed_mph"), NA_real_)
    if (all(is.finite(c(tru_kw, speed))) && speed > 0) {
      kwh_tru <- tru_kw / speed
    }
  }

  truck_g <- prior_value("truck_g_per_ton_mile", NA_real_)
  reefer_extra <- prior_value("reefer_extra_g_per_ton_mile", NA_real_)

  diesel_g_per_gallon <- prior_value_any(c("diesel_co2_g_per_gallon"), 10180)
  diesel_gph <- prior_value_any(c("diesel_tru_gal_per_hour"), NA_real_)
  diesel_startup_gal <- prior_value_any(c("diesel_tru_startup_gal"), 0)
  linehaul_speed <- prior_value_any(c("linehaul_avg_speed_mph", "linehaul_speed_mph"), NA_real_)

  if (identical(variant_row$powertrain[[1]], "diesel")) {
    dry_base <- row_value(dry_factor_row, "co2_g_per_ton_mile", 105)
    if (identical(variant_row$trailer_type[[1]], "dry_van")) {
      intensity <- compute_emissions_intensity(
        powertrain = "diesel",
        default_payload_tons = payload,
        co2_g_per_ton_mile = row_value(factor_row, "co2_g_per_ton_mile", dry_base),
        co2_g_per_mile = row_value(factor_row, "co2_g_per_mile", NA_real_)
      )
      truck_g <- intensity$tractor_g_per_ton_mile
      reefer_extra <- 0
    } else if (identical(variant_row$refrigeration_mode[[1]], "diesel_tru")) {
      truck_g <- dry_base
      if (all(is.finite(c(diesel_gph, linehaul_speed, payload, diesel_g_per_gallon))) && linehaul_speed > 0) {
        reefer_mile <- ((diesel_gph / linehaul_speed) + (diesel_startup_gal / max(distance_miles, 1e-6))) * diesel_g_per_gallon
        reefer_extra <- reefer_mile / payload
      } else {
        total <- row_value(factor_row, "co2_g_per_ton_mile", NA_real_)
        if (is.finite(total) && is.finite(dry_base)) reefer_extra <- max(total - dry_base, 0)
      }
    } else if (identical(variant_row$refrigeration_mode[[1]], "electric_tru")) {
      if (all(is.finite(c(kwh_tru, grid_ci, payload)))) {
        elec <- compute_emissions_intensity(
          powertrain = "bev",
          default_payload_tons = payload,
          kwh_per_mile_tract = 0,
          kwh_per_mile_tru = kwh_tru,
          grid_co2_g_per_kwh = grid_ci
        )
        truck_g <- dry_base
        reefer_extra <- elec$tru_g_per_ton_mile
      }
    }
  }

  if (identical(variant_row$powertrain[[1]], "bev") &&
      all(is.finite(c(kwh_tract, grid_ci, payload)))) {
    kwh_tru_eff <- if (identical(variant_row$refrigeration_mode[[1]], "electric_tru")) kwh_tru else 0
    if (!is.finite(kwh_tru_eff)) kwh_tru_eff <- 0
    intensity <- compute_emissions_intensity(
      powertrain = "bev",
      default_payload_tons = payload,
      kwh_per_mile_tract = kwh_tract,
      kwh_per_mile_tru = kwh_tru_eff,
      grid_co2_g_per_kwh = grid_ci
    )
    truck_g <- intensity$tractor_g_per_ton_mile
    reefer_extra <- intensity$tru_g_per_ton_mile
  }

  if (!is.finite(truck_g)) truck_g <- 105
  if (!is.finite(reefer_extra)) reefer_extra <- 0

  inputs_list <- list(
    FU_kcal = FU_kcal,
    kcal_per_kg_dry = prior_value("kcal_per_kg_dry", dry_kcal),
    kcal_per_kg_reefer = prior_value("kcal_per_kg_reefer", reefer_kcal),
    pkg_kg_per_kg_dry = prior_value("pkg_kg_per_kg_dry", dry_pkg),
    pkg_kg_per_kg_reefer = prior_value("pkg_kg_per_kg_reefer", reefer_pkg),
    distance_miles = distance_miles,
    truck_g_per_ton_mile = truck_g,
    reefer_extra_g_per_ton_mile = reefer_extra,
    util_dry = util_dry,
    util_reefer = util_reefer
  )

  inputs_list$product_mode <- dims$product_mode
  inputs_list$spatial_structure <- dims$spatial_structure
  inputs_list$powertrain_config <- dims$powertrain_config
  inputs_list$regionalized_distance_scale <- distance_scale
  inputs_list$distance_mode <- distance_mode
  inputs_list$facility_id <- facility_id_for_mode
  inputs_list$retail_id <- retail_fixed

  inputs_list$sampling <- priors
  inputs_list$intensity_context <- list(
    powertrain = variant_row$powertrain[[1]],
    trailer_type = variant_row$trailer_type[[1]],
    refrigeration_mode = variant_row$refrigeration_mode[[1]],
    default_payload_tons = payload,
    diesel_truck_g_per_ton_mile = row_value(dry_factor_row, "co2_g_per_ton_mile", 105),
    diesel_co2_g_per_gallon = diesel_g_per_gallon,
    diesel_tru_gal_per_hour = diesel_gph,
    diesel_tru_startup_gal = diesel_startup_gal,
    linehaul_speed_mph = linehaul_speed,
    Crr = prior_value_any(c("Crr", "crr"), 0.006),
    CdA = prior_value_any(c("CdA", "cdA"), 6.5),
    rho_air = prior_value_any(c("rho_air"), 1.2),
    regen_eff = prior_value_any(c("regen_eff"), 0.65),
    drivetrain_eff_diesel = prior_value_any(c("drivetrain_eff_diesel"), 0.4),
    drivetrain_eff_bev = prior_value_any(c("drivetrain_eff_bev"), 0.88),
    base_vehicle_mass_kg = prior_value_any(c("base_vehicle_mass_kg"), 14000),
    battery_kwh = prior_value_any(c("battery_kwh"), 540),
    soc_max = prior_value_any(c("soc_max"), 0.9),
    soc_min = prior_value_any(c("soc_min"), 0.1),
    kwh_per_mile_tract = kwh_tract,
    kwh_per_mile_tru = kwh_tru,
    grid_co2_g_per_kwh = grid_ci
  )

  if (distance_mode == "ROAD_NETWORK_PHYSICS" && nrow(inputs$routes_facility_to_petco) > 0) {
    route_rows <- subset(inputs$routes_facility_to_petco, facility_id == facility_id_for_mode & retail_id == retail_fixed)
    if (nrow(route_rows) > 0) {
      inputs_list$route_options <- route_rows
      if ("route_id" %in% names(route_rows)) {
        inputs_list$intensity_context$route_id_default <- as.character(route_rows$route_id[[1]])
      }
    }
    inputs_list$elevation_profiles <- inputs$route_elevation_profiles
    inputs_list$bev_route_plans <- inputs$bev_route_plans
  }

  list(
    inputs_list = inputs_list,
    scenario_row = scenario_row,
    product_row = product_row,
    factor_row = factor_row,
    distance_row = dist_row,
    priors = priors,
    priors_rows = resolve_sampling_priors(inputs$sampling_priors, variant_row),
    variant_dims = dims
  )
}

build_sampling_from_factors <- function(factors_table, scenario_name = NULL) {
  required_cols <- c("name", "dist", "min", "mode", "max")
  if (!all(required_cols %in% names(factors_table))) {
    return(list())
  }

  if (!is.null(scenario_name) && "scenario" %in% names(factors_table)) {
    factors_table <- subset(factors_table, is.na(scenario) | scenario == scenario_name)
  }

  sampling <- list()
  for (i in seq_len(nrow(factors_table))) {
    row <- factors_table[i, ]
    if (!isTRUE(row$dist == "triangular")) next
    sampling[[row$name]] <- list(
      distribution = "triangular",
      p1 = row$min,
      p2 = row$mode,
      p3 = row$max
    )
  }
  sampling
}

metric_definitions_hash_from_hist_config <- function(hist_config_df) {
  sha256_text(jsonlite::toJSON(hist_config_df, auto_unbox = TRUE))
}

inputs_hash_from_resolved <- function(resolved_inputs_df) {
  sha256_text(jsonlite::toJSON(resolved_inputs_df, auto_unbox = TRUE))
}

write_results_summary <- function(stats, path, hist = NULL) {
  metrics <- names(stats)
  p05 <- p50 <- p95 <- rep(NA_real_, length(metrics))
  if (!is.null(hist)) {
    for (i in seq_along(metrics)) {
      nm <- metrics[[i]]
      if (nm %in% names(hist)) {
        hs <- hist_summary(hist[[nm]])
        p05[[i]] <- hs$p05
        p50[[i]] <- hs$p50
        p95[[i]] <- hs$p95
      }
    }
  }
  out <- data.frame(
    metric = metrics,
    mean = vapply(metrics, function(m) stats[[m]]$mean, numeric(1)),
    var = vapply(metrics, function(m) stats[[m]]$var, numeric(1)),
    min = vapply(metrics, function(m) stats[[m]]$min, numeric(1)),
    max = vapply(metrics, function(m) stats[[m]]$max, numeric(1)),
    p05 = p05,
    p50 = p50,
    p95 = p95,
    stringsAsFactors = FALSE
  )
  utils::write.csv(out, path, row.names = FALSE)
  invisible(path)
}
