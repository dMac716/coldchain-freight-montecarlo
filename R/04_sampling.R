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

draw_from_prior <- function(n, spec) {
  if (is.null(spec$distribution)) {
    # Backward compatibility for legacy triangular specs.
    return(rtri(n, spec$min, spec$mode, spec$max))
  }

  dist <- tolower(spec$distribution)
  p1 <- spec$p1
  p2 <- spec$p2
  p3 <- spec$p3

  if (dist == "fixed") {
    if (!is.finite(p1)) stop("Fixed prior requires finite p1.")
    return(rep(p1, n))
  }

  if (dist == "triangular") {
    return(rtri(n, p1, p2, p3))
  }

  if (dist == "normal") {
    if (!is.finite(p1) || !is.finite(p2) || p2 <= 0) {
      stop("Normal prior requires finite p1(mean), p2(sd>0).")
    }
    return(stats::rnorm(n, mean = p1, sd = p2))
  }

  if (dist == "lognormal") {
    if (!is.finite(p1) || !is.finite(p2) || p2 <= 0) {
      stop("Lognormal prior requires finite p1(meanlog), p2(sdlog>0).")
    }
    return(stats::rlnorm(n, meanlog = p1, sdlog = p2))
  }

  stop("Unsupported prior distribution: ", dist)
}

sample_inputs <- function(inputs, scenario_row, factors_table, n, seed = NULL) {
  if (!is.numeric(n) || length(n) != 1 || !is.finite(n) || n < 1) {
    stop("n must be a finite numeric scalar >= 1.")
  }
  n <- as.integer(n)

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

  has_scenario <- !is.null(scenario_row) && !is.null(names(scenario_row))

  base_value <- function(name) {
    if (has_scenario && name %in% names(scenario_row)) {
      val <- scenario_row[[name]]
      if (!is.na(val)) return(val)
    }
    if (!is.null(inputs[[name]])) return(inputs[[name]])
    stop(paste0("Missing base value for ", name))
  }

  factors_lookup <- NULL
  if (!is.null(factors_table) &&
      all(c("name", "dist", "min", "mode", "max") %in% names(factors_table))) {
    factors_lookup <- split(factors_table, factors_table$name)
  }

  sampling <- inputs$sampling
  sampling_names <- if (is.null(sampling)) character() else names(sampling)
  factor_names <- if (is.null(factors_lookup)) character() else names(factors_lookup)

  out <- vector("list", length(required))
  names(out) <- required
  for (i in seq_along(required)) {
    nm <- required[[i]]
    sampled <- FALSE
    if (nm %in% factor_names) {
      row <- factors_lookup[[nm]][1, , drop = FALSE]
      if (row$dist[1] == "triangular") {
        out[[i]] <- rtri(n, row$min[1], row$mode[1], row$max[1])
        sampled <- TRUE
      }
    }
    if (!sampled && nm %in% sampling_names) {
      out[[i]] <- draw_from_prior(n, sampling[[nm]])
      sampled <- TRUE
    }
    if (!sampled) {
      out[[i]] <- rep(base_value(nm), n)
    }
  }

  as.data.frame(out, stringsAsFactors = FALSE)
}
