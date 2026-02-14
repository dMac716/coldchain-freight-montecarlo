read_inputs_local <- function(dir = "data/inputs_local") {
  list(
    products = utils::read.csv(file.path(dir, "products.csv"), stringsAsFactors = FALSE),
    scenarios = utils::read.csv(file.path(dir, "scenarios.csv"), stringsAsFactors = FALSE),
    factors = utils::read.csv(file.path(dir, "factors.csv"), stringsAsFactors = FALSE),
    histogram_config = utils::read.csv(file.path(dir, "histogram_config.csv"), stringsAsFactors = FALSE),
    assumptions = utils::read.csv(file.path(dir, "assumptions_used.csv"), stringsAsFactors = FALSE)
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

build_sampling_from_factors <- function(factors_table, scenario_name = NULL) {
  if (!is.null(scenario_name) && "scenario" %in% names(factors_table)) {
    factors_table <- subset(factors_table, is.na(scenario) | scenario == scenario_name)
  }

  sampling <- list()
  for (i in seq_len(nrow(factors_table))) {
    row <- factors_table[i, ]
    if (!isTRUE(row$dist == "triangular")) next
    sampling[[row$name]] <- list(
      min = row$min,
      mode = row$mode,
      max = row$max
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

write_results_summary <- function(stats, path) {
  metrics <- names(stats)
  out <- data.frame(
    metric = metrics,
    mean = vapply(metrics, function(m) stats[[m]]$mean, numeric(1)),
    var = vapply(metrics, function(m) stats[[m]]$var, numeric(1)),
    min = vapply(metrics, function(m) stats[[m]]$min, numeric(1)),
    max = vapply(metrics, function(m) stats[[m]]$max, numeric(1)),
    stringsAsFactors = FALSE
  )
  utils::write.csv(out, path, row.names = FALSE)
  invisible(path)
}
