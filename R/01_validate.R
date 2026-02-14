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
