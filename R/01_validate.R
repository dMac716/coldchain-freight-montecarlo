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

validate_inputs <- function(inputs_list) {
  required <- c(
    "FU_kcal",
    "kcal_per_kg_dry", "kcal_per_kg_reefer",
    "pkg_kg_per_kg_dry", "pkg_kg_per_kg_reefer",
    "distance_miles",
    "truck_g_per_ton_mile",
    "reefer_extra_g_per_ton_mile",
    "util_dry", "util_reefer"
  )
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

assert_mode_data_ready <- function(mode, scenarios_df, histogram_config_df, scenario_name = NULL) {
  mode <- normalize_run_mode(mode)
  if (mode != "REAL_RUN") return(invisible(TRUE))

  if (!is.null(scenario_name) && "scenario" %in% names(scenarios_df)) {
    scenario_row <- subset(scenarios_df, scenario == scenario_name)
    if (nrow(scenario_row) == 0) {
      stop("REAL_RUN gate failed: scenario not found in scenarios.csv.")
    }
    if ("status" %in% names(scenario_row) &&
        any(scenario_row$status == "MISSING_DISTANCE_DATA", na.rm = TRUE)) {
      stop("REAL_RUN gate failed: scenarios.csv still marked MISSING_DISTANCE_DATA.")
    }
  }

  if ("status" %in% names(histogram_config_df) &&
      any(histogram_config_df$status == "TO_CALIBRATE_AFTER_FIRST_REAL_RUN", na.rm = TRUE)) {
    stop("REAL_RUN gate failed: histogram_config.csv still marked TO_CALIBRATE_AFTER_FIRST_REAL_RUN.")
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
