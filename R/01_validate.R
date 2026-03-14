validate_triangular_params <- function(min, mode, max) {
  if (!is.numeric(min) || !is.numeric(mode) || !is.numeric(max)) {
    stop("Triangular params must be numeric.")
  }
  if (length(min) != 1 || length(mode) != 1 || length(max) != 1) {
    stop("Triangular params must be length 1.")
  }
  if (!is.finite(min) || !is.finite(mode) || !is.finite(max)) {
    stop("Triangular params must be finite.")
  }
  if (min >= max) {
    stop("Triangular params require min < max.")
  }
  if (mode < min || mode > max) {
    stop("Triangular params require min <= mode <= max.")
  }
  invisible(TRUE)
}

required_model_param_ids <- function() {
  c(
    "FU_kcal",
    "kcal_per_kg_dry", "kcal_per_kg_reefer",
    "pkg_kg_per_kg_dry", "pkg_kg_per_kg_reefer",
    "distance_miles",
    "truck_g_per_ton_mile", "reefer_extra_g_per_ton_mile",
    "util_dry", "util_reefer"
  )
}

validate_inputs <- function(inputs_list) {
  required <- required_model_param_ids()
  missing <- setdiff(required, names(inputs_list))
  if (length(missing) > 0) {
    stop(paste0("Missing required inputs: ", paste(missing, collapse = ", ")))
  }

  for (nm in required) {
    val <- inputs_list[[nm]]
    if (!is.numeric(val) || length(val) != 1 || !is.finite(val)) {
      stop(paste0("Input ", nm, " must be a finite numeric scalar."))
    }
  }

  if (inputs_list$FU_kcal <= 0) stop("FU_kcal must be > 0.")
  if (inputs_list$kcal_per_kg_dry <= 0 || inputs_list$kcal_per_kg_reefer <= 0) {
    stop("kcal_per_kg_* must be > 0.")
  }
  if (inputs_list$pkg_kg_per_kg_dry < 0 || inputs_list$pkg_kg_per_kg_reefer < 0) {
    stop("pkg_kg_per_kg_* must be >= 0.")
  }
  if (inputs_list$distance_miles < 0) stop("distance_miles must be >= 0.")
  if (inputs_list$truck_g_per_ton_mile < 0) stop("truck_g_per_ton_mile must be >= 0.")
  if (inputs_list$reefer_extra_g_per_ton_mile < 0) stop("reefer_extra_g_per_ton_mile must be >= 0.")
  if (inputs_list$util_dry <= 0 || inputs_list$util_reefer <= 0) {
    stop("util_* must be > 0.")
  }
  invisible(TRUE)
}

validate_hist_config <- function(hist_config) {
  required <- c("metric", "min", "max", "bins")
  if (!is.list(hist_config)) stop("hist_config must be a list.")
  missing <- setdiff(required, names(hist_config))
  if (length(missing) > 0) {
    stop(paste0("hist_config missing fields: ", paste(missing, collapse = ", ")))
  }
  n <- length(hist_config$metric)
  if (any(c(length(hist_config$min), length(hist_config$max), length(hist_config$bins)) != n)) {
    stop("hist_config fields must have equal lengths.")
  }
  if (any(!is.finite(hist_config$min)) || any(!is.finite(hist_config$max))) {
    stop("hist_config min/max must be finite.")
  }
  if (any(hist_config$max <= hist_config$min)) stop("hist_config max must be > min.")
  if (any(hist_config$bins < 1)) stop("hist_config bins must be >= 1.")
  invisible(TRUE)
}

validate_sampling_priors <- function(priors_df) {
  if (nrow(priors_df) == 0) return(invisible(TRUE))
  required <- c("param_id", "distribution", "p1", "p2", "p3", "units", "applies_to", "source_id", "source_page", "status", "notes")
  missing <- setdiff(required, names(priors_df))
  if (length(missing) > 0) stop("sampling_priors.csv missing columns: ", paste(missing, collapse = ", "))

  allowed <- c("triangular", "lognormal", "normal", "fixed")
  d <- tolower(trimws(priors_df$distribution))
  if (any(!d %in% allowed)) {
    bad <- unique(priors_df$distribution[!d %in% allowed])
    stop("sampling_priors.csv contains unsupported distributions: ", paste(bad, collapse = ", "))
  }

  for (i in seq_len(nrow(priors_df))) {
    dist <- d[[i]]
    p1 <- suppressWarnings(as.numeric(priors_df$p1[[i]]))
    p2 <- suppressWarnings(as.numeric(priors_df$p2[[i]]))
    p3 <- suppressWarnings(as.numeric(priors_df$p3[[i]]))

    if (dist == "fixed" && !is.finite(p1)) {
      stop("sampling_priors row ", i, " fixed distribution requires finite p1.")
    }
    if (dist == "triangular") {
      validate_triangular_params(p1, p2, p3)
    }
    if (dist == "normal" && (!is.finite(p1) || !is.finite(p2) || p2 <= 0)) {
      stop("sampling_priors row ", i, " normal requires finite p1 and p2>0.")
    }
    if (dist == "lognormal" && (!is.finite(p1) || !is.finite(p2) || p2 <= 0)) {
      stop("sampling_priors row ", i, " lognormal requires finite p1 and p2>0.")
    }
  }

  invisible(TRUE)
}

assert_required_priors_present <- function(sampling_map, required_params = required_model_param_ids()) {
  missing <- setdiff(required_params, names(sampling_map))
  if (length(missing) > 0) {
    stop("Required sampling priors missing for params: ", paste(missing, collapse = ", "))
  }
  invisible(TRUE)
}

validate_artifact_schema_local <- function(path_json) {
  if (!file.exists(path_json)) stop("Artifact JSON file not found.")
  payload <- jsonlite::fromJSON(path_json, simplifyVector = FALSE)

  required <- c(
    "run_id", "run_group_id", "model_version", "inputs_hash",
    "metric_definitions_hash", "timestamp_utc", "rng_kind", "seed",
    "n_chunk", "metrics", "integrity"
  )
  missing <- setdiff(required, names(payload))
  if (length(missing) > 0) {
    stop(paste0("Artifact missing required fields: ", paste(missing, collapse = ", ")))
  }

  metrics <- payload$metrics
  metric_names <- c("gco2_dry", "gco2_reefer", "diff_gco2", "ratio")
  if (!all(metric_names %in% names(metrics))) {
    stop("Artifact metrics missing required metric names.")
  }

  for (nm in metric_names) {
    m <- metrics[[nm]]
    if (is.null(m$histogram)) stop(paste0("Metric ", nm, " missing histogram."))
    h <- m$histogram
    if (length(h$bin_edges) != length(h$bin_counts) + 1) {
      stop(paste0("Histogram ", nm, ": length(bin_edges) must equal length(bin_counts)+1."))
    }
    if (any(diff(unlist(h$bin_edges)) <= 0)) {
      stop(paste0("Histogram ", nm, ": bin_edges must be strictly increasing."))
    }
    total <- sum(unlist(h$bin_counts)) + h$underflow + h$overflow
    if (!isTRUE(all.equal(total, m$n))) {
      stop(paste0("Histogram ", nm, ": n must equal sum(counts)+underflow+overflow."))
    }
  }

  if (!is.null(payload$integrity$artifact_sha256) && exists("artifact_canonical_sha256")) {
    expected <- artifact_canonical_sha256(payload)
    actual <- payload$integrity$artifact_sha256
    if (!identical(expected, actual)) {
      stop(
        paste0(
          "Artifact checksum mismatch. expected=", expected,
          " actual=", actual
        )
      )
    }
  }
  invisible(TRUE)
}

normalize_run_mode <- function(mode) {
  if (is.null(mode) || !is.character(mode) || length(mode) != 1 || !nzchar(mode)) {
    return("SMOKE_LOCAL")
  }
  out <- toupper(mode)
  allowed <- c("SMOKE_LOCAL", "REAL_RUN")
  if (!out %in% allowed) {
    stop("Invalid mode. Allowed values: SMOKE_LOCAL, REAL_RUN.")
  }
  out
}

normalize_distance_mode <- function(distance_mode) {
  if (is.null(distance_mode) || !nzchar(as.character(distance_mode))) {
    return("FAF_DISTRIBUTION")
  }
  m <- toupper(trimws(as.character(distance_mode)))
  allowed <- c("FAF_DISTRIBUTION", "ROAD_NETWORK_FIXED_DEST", "ROAD_NETWORK_PHYSICS")
  if (!m %in% allowed) {
    stop("Invalid distance mode. Allowed values: ", paste(allowed, collapse = ", "))
  }
  m
}

normalize_product_mode <- function(mode) {
  if (is.null(mode) || !nzchar(as.character(mode))) {
    stop("product_mode is required.")
  }
  m <- toupper(trimws(as.character(mode)))
  if (m %in% c("REFRIGERATED", "REEFER", "REFRIG")) return("REFRIGERATED")
  if (m %in% c("DRY", "DRY_VAN")) return("DRY")
  stop("Invalid product_mode. Allowed values: DRY, REFRIGERATED.")
}

normalize_spatial_structure <- function(structure) {
  if (is.null(structure) || !nzchar(as.character(structure))) {
    stop("spatial_structure is required.")
  }
  s <- toupper(trimws(as.character(structure)))
  if (grepl("CENTRAL", s, fixed = TRUE)) return("CENTRALIZED")
  if (grepl("REGIONAL", s, fixed = TRUE)) return("REGIONALIZED")
  if (grepl("SMOKE", s, fixed = TRUE)) return("SMOKE_LOCAL")
  stop("Invalid spatial_structure. Allowed values: CENTRALIZED, REGIONALIZED, SMOKE_LOCAL.")
}

normalize_powertrain_config <- function(config) {
  if (is.null(config) || !nzchar(as.character(config))) {
    stop("powertrain_config is required.")
  }
  c0 <- toupper(trimws(as.character(config)))
  if (grepl("BEV", c0, fixed = TRUE)) return("BEV_TRU_ELECTRIC")
  if (grepl("DIESEL", c0, fixed = TRUE)) return("DIESEL_TRU_DIESEL")
  stop("Invalid powertrain_config. Allowed values: BEV_TRU_ELECTRIC, DIESEL_TRU_DIESEL.")
}

validate_road_distance_fixed_cache <- function(df, retail_id = "PETCO_DAVIS_COVELL") {
  required <- c(
    "facility_id", "retail_id", "distance_km", "duration_min", "provider", "profile", "timestamp_utc"
  )
  missing <- setdiff(required, names(df))
  if (length(missing) > 0) stop("road_distance_facility_to_retail.csv missing columns: ", paste(missing, collapse = ", "))
  expected_fac <- c("FACILITY_REFRIG_ENNIS", "FACILITY_DRY_TOPEKA")
  rid <- retail_id
  hit <- subset(df, retail_id == rid)
  if (nrow(hit) < 2) stop("Road distance cache incomplete for retail_id=", retail_id)
  if (!all(expected_fac %in% hit$facility_id)) {
    stop("Road distance cache missing expected facilities for ", retail_id, ": ", paste(setdiff(expected_fac, hit$facility_id), collapse = ", "))
  }
  v <- hit[match(expected_fac, hit$facility_id), , drop = FALSE]
  if (any(!is.finite(as.numeric(v$distance_km))) || any(as.numeric(v$distance_km) <= 0)) {
    stop("Road distance cache has invalid distance_km.")
  }
  if (any(!is.finite(as.numeric(v$duration_min))) || any(as.numeric(v$duration_min) <= 0)) {
    stop("Road distance cache has invalid duration_min.")
  }
  invisible(TRUE)
}

assert_mode_data_ready <- function(mode, scenarios_df, histogram_config_df, scenario_name = NULL,
                                   variant_row = NULL, inputs = NULL, priors_map = NULL,
                                   distance_mode = "FAF_DISTRIBUTION") {
  mode <- normalize_run_mode(mode)
  distance_mode <- normalize_distance_mode(distance_mode)
  if (mode != "REAL_RUN") return(invisible(TRUE))

  id_col <- if ("scenario_id" %in% names(scenarios_df)) "scenario_id" else if ("scenario" %in% names(scenarios_df)) "scenario" else NULL
  if (!is.null(scenario_name) && !is.null(id_col)) {
    scenario_row <- scenarios_df[scenarios_df[[id_col]] == scenario_name, , drop = FALSE]
    if (nrow(scenario_row) == 0) {
      stop("REAL_RUN gate failed: scenario not found in scenarios.csv.")
    }
    if ("status" %in% names(scenario_row) &&
        any(scenario_row$status == "MISSING_DISTANCE_DATA", na.rm = TRUE)) {
      stop("REAL_RUN gate failed: scenarios.csv still marked MISSING_DISTANCE_DATA.")
    }

    if ("distance_distribution_id" %in% names(scenario_row) && !is.null(inputs) && nrow(inputs$distance_distributions) > 0) {
      dd_id <- scenario_row$distance_distribution_id[[1]]
      dd <- subset(inputs$distance_distributions, distance_distribution_id == dd_id)
      if (nrow(dd) == 0) {
        stop("REAL_RUN gate failed: distance_distribution_id not found in data/derived/faf_distance_distributions.csv.")
      }
      if ("status" %in% names(dd) && !identical(dd$status[[1]], "OK")) {
        stop("REAL_RUN gate failed: distance distribution is not OK for REAL_RUN.")
      }
    }
  }

  if ("status" %in% names(histogram_config_df) &&
      any(histogram_config_df$status == "TO_CALIBRATE_AFTER_FIRST_REAL_RUN", na.rm = TRUE)) {
    stop("REAL_RUN gate failed: histogram_config.csv still marked TO_CALIBRATE_AFTER_FIRST_REAL_RUN.")
  }

  if (!is.null(variant_row)) {
    if ("status" %in% names(variant_row) &&
        any(variant_row$status %in% c("NEEDS_SOURCE_VALUE", "MISSING_DATA", "MISSING_BEV_INTENSITY"), na.rm = TRUE)) {
      stop("REAL_RUN gate failed: scenario_matrix variant status indicates unresolved source values.")
    }

    if (!is.null(inputs) && nrow(inputs$emissions_factors) > 0) {
      ef <- subset(
        inputs$emissions_factors,
        powertrain == variant_row$powertrain[[1]] &
          trailer_type == variant_row$trailer_type[[1]] &
          refrigeration_mode == variant_row$refrigeration_mode[[1]]
      )
      if (nrow(ef) == 0) {
        stop("REAL_RUN gate failed: emissions_factors row not found for requested variant.")
      }
      if ("status" %in% names(ef) &&
          any(ef$status %in% c("NEEDS_SOURCE_VALUE", "MISSING_DATA", "MISSING_BEV_INTENSITY"), na.rm = TRUE)) {
        stop("REAL_RUN gate failed: emissions_factors contains unresolved source values for requested variant.")
      }
    }

    if (!is.null(priors_map)) {
      assert_required_priors_present(priors_map, required_model_param_ids())
      statuses <- vapply(priors_map, function(p) if (!is.null(p$status)) p$status else "OK", character(1))
      if (any(statuses %in% c("NEEDS_SOURCE_VALUE", "MISSING_DATA"), na.rm = TRUE)) {
        stop("REAL_RUN gate failed: sampling_priors contains NEEDS_SOURCE_VALUE for requested variant.")
      }
    }
  }

  if (distance_mode %in% c("ROAD_NETWORK_FIXED_DEST", "ROAD_NETWORK_PHYSICS")) {
    if (is.null(inputs) || is.null(inputs$road_distance_fixed) || nrow(inputs$road_distance_fixed) == 0) {
      stop("REAL_RUN gate failed: data/derived/road_distance_facility_to_retail.csv is required for distance_mode=", distance_mode)
    }
    validate_road_distance_fixed_cache(inputs$road_distance_fixed, retail_id = "PETCO_DAVIS_COVELL")
    if (distance_mode == "ROAD_NETWORK_PHYSICS") {
      if (is.null(inputs$routes_facility_to_petco) || nrow(inputs$routes_facility_to_petco) == 0) {
        stop("REAL_RUN gate failed: routes_facility_to_petco.csv is required for ROAD_NETWORK_PHYSICS.")
      }
      if (is.null(inputs$route_elevation_profiles) || nrow(inputs$route_elevation_profiles) == 0) {
        stop("REAL_RUN gate failed: route_elevation_profiles.csv is required for ROAD_NETWORK_PHYSICS.")
      }
      if (!is.null(variant_row) && "powertrain" %in% names(variant_row) &&
          identical(as.character(variant_row$powertrain[[1]]), "bev")) {
        if (is.null(inputs$bev_route_plans) || nrow(inputs$bev_route_plans) == 0) {
          stop("REAL_RUN gate failed: bev_route_plans.csv is required for BEV ROAD_NETWORK_PHYSICS runs.")
        }
      }
    }
  }

  invisible(TRUE)
}

assert_scenarios_distance_linkage <- function(scenarios_df, distance_df) {
  if (!all(c("scenario_id", "distance_distribution_id") %in% names(scenarios_df))) {
    stop("scenarios.csv missing scenario_id or distance_distribution_id columns.")
  }
  ok_rows <- scenarios_df
  if ("status" %in% names(ok_rows)) {
    ok_rows <- subset(ok_rows, status == "OK")
  }
  if (nrow(ok_rows) == 0) return(invisible(TRUE))

  missing <- setdiff(ok_rows$distance_distribution_id, distance_df$distance_distribution_id)
  if (length(missing) > 0) {
    stop("Scenarios marked OK reference missing distance_distribution_id: ", paste(missing, collapse = ", "))
  }
  invisible(TRUE)
}

assert_variant_dimensions_present <- function(scenario_matrix_df) {
  required <- c(
    "variant_id", "scenario_id", "product_mode", "spatial_structure",
    "powertrain", "powertrain_config", "trailer_type", "refrigeration_mode"
  )
  missing <- setdiff(required, names(scenario_matrix_df))
  if (length(missing) > 0) {
    stop("scenario_matrix.csv missing required dimension columns: ", paste(missing, collapse = ", "))
  }
  invisible(TRUE)
}

hist_coverage_ratio <- function(hist, n_total = NULL) {
  if (is.null(n_total)) {
    n_total <- sum(hist$counts) + hist$underflow + hist$overflow
  }
  if (!is.finite(n_total) || n_total <= 0) return(0)
  (hist$underflow + hist$overflow) / n_total
}

enforce_hist_coverage <- function(hist_list, n_list = NULL, mode = "SMOKE_LOCAL",
                                  threshold = 0.001, context = "run") {
  mode <- normalize_run_mode(mode)
  for (nm in names(hist_list)) {
    n_total <- NULL
    if (!is.null(n_list) && nm %in% names(n_list)) {
      n_total <- n_list[[nm]]
    }
    ratio <- hist_coverage_ratio(hist_list[[nm]], n_total)
    if (ratio > threshold) {
      msg <- paste0(
        "Histogram coverage threshold exceeded for metric ", nm,
        " in ", context, ": ratio=",
        format(ratio, digits = 6), " > ", format(threshold, digits = 6)
      )
      if (mode == "REAL_RUN") {
        stop(msg)
      } else {
        warning(msg, call. = FALSE)
      }
    }
  }
  invisible(TRUE)
}
