#' Run Monte Carlo Chunk
#'
#' Executes a chunk of Monte Carlo simulations with specified random seed
#' for reproducibility. This function is designed to be run in parallel
#' across distributed compute nodes.
#'
#' @param chunk_id Integer. Unique identifier for this chunk.
#' @param chunk_size Integer. Number of samples to generate in this chunk.
#' @param seed Integer. Random seed for reproducibility.
#' @param params List. Parameters for the simulation including:
#'   \describe{
#'     \item{distance_mean}{Mean distance in km}
#'     \item{distance_sd}{Standard deviation of distance}
#'     \item{payload_mean}{Mean payload in tons}
#'     \item{payload_sd}{Standard deviation of payload}
#'     \item{temp_mean}{Mean ambient temperature}
#'     \item{temp_sd}{Standard deviation of temperature}
#'     \item{fuel_efficiency_mean}{Mean fuel efficiency}
#'     \item{fuel_efficiency_sd}{Standard deviation of fuel efficiency}
#'     \item{refrigeration_prob}{Probability of refrigeration}
#'   }
#'
#' @return A list containing:
#'   \item{chunk_id}{The chunk identifier}
#'   \item{n_samples}{Number of samples generated}
#'   \item{seed}{Random seed used}
#'   \item{results}{Data frame of emission results}
#'   \item{moments}{List of exact statistical moments}
#'   \item{histogram_dry}{Histogram for dry freight emissions}
#'   \item{histogram_refrigerated}{Histogram for refrigerated freight emissions}
#'
#' @export
#' @examples
#' params <- list(
#'   distance_mean = 500, distance_sd = 100,
#'   payload_mean = 20, payload_sd = 5,
#'   temp_mean = 20, temp_sd = 5,
#'   fuel_efficiency_mean = 30, fuel_efficiency_sd = 5,
#'   refrigeration_prob = 0.3
#' )
#' result <- run_mc_chunk(1, 1000, 12345, params)
run_mc_chunk <- function(chunk_id, chunk_size, seed, params) {
  
  # Validate inputs
  validate_inputs(list(
    chunk_size = chunk_size
  ))
  
  # Set seed for reproducibility
  set.seed(seed)
  
  # Log this chunk execution
  log_event("chunk_start", list(
    chunk_id = chunk_id,
    chunk_size = chunk_size,
    seed = seed,
    timestamp = Sys.time()
  ))
  
  # Generate random inputs
  distance_km <- rnorm(chunk_size, params$distance_mean, params$distance_sd)
  payload_tons <- rnorm(chunk_size, params$payload_mean, params$payload_sd)
  ambient_temp_c <- rnorm(chunk_size, params$temp_mean, params$temp_sd)
  fuel_efficiency <- rnorm(chunk_size, params$fuel_efficiency_mean, params$fuel_efficiency_sd)
  is_refrigerated <- runif(chunk_size) < params$refrigeration_prob
  
  # Ensure positive values
  distance_km <- pmax(distance_km, 1)
  payload_tons <- pmax(payload_tons, 0.1)
  fuel_efficiency <- pmax(fuel_efficiency, 10)
  
  # Calculate emissions for each sample
  results <- data.frame(
    sample_id = seq_len(chunk_size),
    distance_km = distance_km,
    payload_tons = payload_tons,
    ambient_temp_c = ambient_temp_c,
    fuel_efficiency = fuel_efficiency,
    is_refrigerated = is_refrigerated,
    fuel_consumption_l = numeric(chunk_size),
    co2_emissions_kg = numeric(chunk_size),
    total_cost_usd = numeric(chunk_size)
  )
  
  for (i in seq_len(chunk_size)) {
    emissions <- calculate_emissions(
      distance_km[i],
      payload_tons[i],
      is_refrigerated[i],
      ambient_temp_c[i],
      fuel_efficiency[i]
    )
    results$fuel_consumption_l[i] <- emissions$fuel_consumption_l
    results$co2_emissions_kg[i] <- emissions$co2_emissions_kg
    results$total_cost_usd[i] <- emissions$total_cost_usd
  }
  
  # Calculate exact moments for merging
  moments <- calculate_moments(results$co2_emissions_kg)
  
  # Create histograms by type
  dry_emissions <- results$co2_emissions_kg[!results$is_refrigerated]
  refrig_emissions <- results$co2_emissions_kg[results$is_refrigerated]
  
  hist_dry <- create_histogram(dry_emissions, "dry")
  hist_refrigerated <- create_histogram(refrig_emissions, "refrigerated")
  
  # Log completion
  log_event("chunk_complete", list(
    chunk_id = chunk_id,
    n_samples = chunk_size,
    mean_co2 = mean(results$co2_emissions_kg),
    timestamp = Sys.time()
  ))
  
  return(list(
    chunk_id = chunk_id,
    n_samples = chunk_size,
    seed = seed,
    results = results,
    moments = moments,
    histogram_dry = hist_dry,
    histogram_refrigerated = hist_refrigerated
  ))
}


#' Calculate Statistical Moments
#'
#' Calculates exact statistical moments for merging.
#'
#' @param x Numeric vector of values.
#'
#' @return List containing n, mean, variance, skewness, kurtosis.
#'
#' @keywords internal
calculate_moments <- function(x) {
  n <- length(x)
  if (n == 0) {
    return(list(n = 0, mean = NA, variance = NA, skewness = NA, kurtosis = NA))
  }
  
  mean_x <- mean(x)
  
  if (n == 1) {
    return(list(n = n, mean = mean_x, variance = 0, skewness = NA, kurtosis = NA))
  }
  
  # Calculate centered moments
  centered <- x - mean_x
  m2 <- sum(centered^2) / n
  m3 <- sum(centered^3) / n
  m4 <- sum(centered^4) / n
  
  variance <- m2 * n / (n - 1)  # Unbiased variance
  
  # Standardized moments
  if (m2 > 0) {
    skewness <- m3 / (m2^(3/2))
    kurtosis <- m4 / (m2^2) - 3  # Excess kurtosis
  } else {
    skewness <- NA
    kurtosis <- NA
  }
  
  return(list(
    n = n,
    mean = mean_x,
    variance = variance,
    m2 = m2,
    m3 = m3,
    m4 = m4,
    skewness = skewness,
    kurtosis = kurtosis
  ))
}
