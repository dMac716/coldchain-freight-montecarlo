metric_moments <- function(x) {
  x <- x[is.finite(x)]
  n <- length(x)
  if (n == 0) stop("metric_moments requires at least one finite value.")
  sum_ <- sum(x)
  sum_sq <- as.numeric(crossprod(x))
  min_ <- min(x)
  max_ <- max(x)
  mean_ <- sum_ / n
  var_ <- (sum_sq / n) - mean_^2

  list(
    n = n,
    sum = sum_,
    sum_sq = sum_sq,
    min = min_,
    max = max_,
    mean = mean_,
    var = var_
  )
}

run_monte_carlo_chunk <- function(inputs, hist_config, n, seed) {
  validate_inputs(inputs)
  validate_hist_config(hist_config)

  if (!is.null(seed)) set.seed(seed)
  rng_kind <- paste(RNGkind(), collapse = ",")

  # RNG is initialized once above; avoid reseeding inside the sampling helper.
  samples <- sample_inputs(inputs = inputs, scenario_row = NULL, factors_table = NULL, n = n, seed = NULL)

  mass_dry <- mass_per_fu_kg(samples$FU_kcal, samples$kcal_per_kg_dry, samples$pkg_kg_per_kg_dry)
  mass_reefer <- mass_per_fu_kg(samples$FU_kcal, samples$kcal_per_kg_reefer, samples$pkg_kg_per_kg_reefer)

  gco2_dry <- kg_to_tons(mass_dry) *
    samples$distance_miles *
    samples$truck_g_per_ton_mile *
    samples$util_dry

  gco2_reefer <- kg_to_tons(mass_reefer) *
    samples$distance_miles *
    (samples$truck_g_per_ton_mile + samples$reefer_extra_g_per_ton_mile) *
    samples$util_reefer

  diff_gco2 <- gco2_reefer - gco2_dry
  ratio <- ifelse(gco2_dry == 0, NA_real_, gco2_reefer / gco2_dry)

  metrics <- list(
    gco2_dry = gco2_dry,
    gco2_reefer = gco2_reefer,
    diff_gco2 = diff_gco2,
    ratio = ratio
  )

  hist_edges <- build_hist_edges(hist_config)
  stats <- list()
  hists <- list()
  for (nm in names(metrics)) {
    stats[[nm]] <- metric_moments(metrics[[nm]])
    hists[[nm]] <- make_histogram(metrics[[nm]], hist_edges[[nm]])
  }

  list(
    stats = stats,
    hist = hists,
    metadata = list(
      seed = seed,
      rng_kind = rng_kind,
      n = n,
      inputs_hash = NA_character_,
      metric_definitions_hash = NA_character_
    )
  )
}

merge_moments <- function(list_of_moment_objects) {
  if (length(list_of_moment_objects) == 0) stop("No moments to merge.")

  n <- sum(vapply(list_of_moment_objects, function(m) m$n, numeric(1)))
  sum_ <- sum(vapply(list_of_moment_objects, function(m) m$sum, numeric(1)))
  sum_sq <- sum(vapply(list_of_moment_objects, function(m) m$sum_sq, numeric(1)))
  min_ <- min(vapply(list_of_moment_objects, function(m) m$min, numeric(1)))
  max_ <- max(vapply(list_of_moment_objects, function(m) m$max, numeric(1)))
  mean_ <- sum_ / n
  var_ <- (sum_sq / n) - mean_^2

  list(
    n = n,
    sum = sum_,
    sum_sq = sum_sq,
    min = min_,
    max = max_,
    mean = mean_,
    var = var_
  )
}

merge_chunk_results <- function(chunk_results) {
  if (length(chunk_results) == 0) stop("chunk_results must be non-empty.")

  metrics <- names(chunk_results[[1]]$stats)
  merged_stats <- list()
  merged_hist <- list()

  for (nm in metrics) {
    merged_stats[[nm]] <- merge_moments(lapply(chunk_results, function(cr) cr$stats[[nm]]))
    merged_hist[[nm]] <- merge_histograms(lapply(chunk_results, function(cr) cr$hist[[nm]]))
  }

  list(stats = merged_stats, hist = merged_hist)
}
