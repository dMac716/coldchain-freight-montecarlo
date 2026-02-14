rtri <- function(n, min, mode, max) {
  validate_triangular_params(min, mode, max)
  u <- stats::runif(n)
  c <- (mode - min) / (max - min)
  out <- ifelse(
    u < c,
    min + sqrt(u * (max - min) * (mode - min)),
    max - sqrt((1 - u) * (max - min) * (max - mode))
  )
  out
}

sample_inputs <- function(inputs, scenario_row, factors_table, n, seed = NULL) {
  required <- c(
    "FU_kcal",
    "kcal_per_kg_dry", "kcal_per_kg_reefer",
    "pkg_kg_per_kg_dry", "pkg_kg_per_kg_reefer",
    "distance_miles",
    "truck_g_per_ton_mile",
    "reefer_extra_g_per_ton_mile",
    "util_dry", "util_reefer"
  )

  if (!is.null(seed)) set.seed(seed)

  base_value <- function(name) {
    if (!is.null(scenario_row) && name %in% names(scenario_row)) {
      val <- scenario_row[[name]]
      if (!is.na(val)) return(val)
    }
    if (!is.null(inputs[[name]])) return(inputs[[name]])
    stop(paste0("Missing base value for ", name))
  }

  factors_lookup <- NULL
  if (!is.null(factors_table)) {
    factors_lookup <- split(factors_table, factors_table$name)
  }

  sampling <- inputs$sampling

  out <- list()
  for (nm in required) {
    sampled <- FALSE
    if (!is.null(factors_lookup) && nm %in% names(factors_lookup)) {
      row <- factors_lookup[[nm]][1, , drop = FALSE]
      if (row$dist[1] == "triangular") {
        out[[nm]] <- rtri(n, row$min[1], row$mode[1], row$max[1])
        sampled <- TRUE
      }
    }
    if (!sampled && !is.null(sampling) && nm %in% names(sampling)) {
      tri <- sampling[[nm]]
      out[[nm]] <- rtri(n, tri$min, tri$mode, tri$max)
      sampled <- TRUE
    }
    if (!sampled) {
      out[[nm]] <- rep(base_value(nm), n)
    }
  }

  as.data.frame(out, stringsAsFactors = FALSE)
}
