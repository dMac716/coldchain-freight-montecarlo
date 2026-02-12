#' Utility Functions for coldchainfreight
#'
#' @description Internal utility functions for the package.
#' @keywords internal
#' @name utils
NULL


#' Print Chunk Summary
#'
#' Prints a formatted summary of a Monte Carlo chunk result.
#'
#' @param chunk A chunk result from \code{\link{run_mc_chunk}}.
#'
#' @return NULL (invisibly). Prints to console.
#'
#' @export
#' @examples
#' \dontrun{
#' params <- list(distance_mean = 500, distance_sd = 100,
#'                payload_mean = 20, payload_sd = 5,
#'                temp_mean = 20, temp_sd = 5,
#'                fuel_efficiency_mean = 30, fuel_efficiency_sd = 5,
#'                refrigeration_prob = 0.3)
#' chunk <- run_mc_chunk(1, 1000, 12345, params)
#' print_chunk_summary(chunk)
#' }
print_chunk_summary <- function(chunk) {
  
  if (!is.list(chunk) || is.null(chunk$chunk_id)) {
    stop("Input must be a valid chunk result from run_mc_chunk()")
  }
  
  cat("=== Monte Carlo Chunk Summary ===\n")
  cat(sprintf("Chunk ID: %d\n", chunk$chunk_id))
  cat(sprintf("Samples: %s\n", format(chunk$n_samples, big.mark = ",")))
  cat(sprintf("Random Seed: %d\n", chunk$seed))
  cat("\n")
  
  cat("Statistical Moments:\n")
  cat(sprintf("  Mean: %.2f kg CO2\n", chunk$moments$mean))
  cat(sprintf("  SD: %.2f kg CO2\n", sqrt(chunk$moments$variance)))
  if (!is.na(chunk$moments$skewness)) {
    cat(sprintf("  Skewness: %.3f\n", chunk$moments$skewness))
  }
  if (!is.na(chunk$moments$kurtosis)) {
    cat(sprintf("  Kurtosis: %.3f\n", chunk$moments$kurtosis))
  }
  cat("\n")
  
  # Breakdown by type
  n_dry <- sum(!chunk$results$is_refrigerated)
  n_refrig <- sum(chunk$results$is_refrigerated)
  
  cat("Freight Type Breakdown:\n")
  cat(sprintf("  Dry: %d samples (%.1f%%)\n", 
              n_dry, 100 * n_dry / chunk$n_samples))
  cat(sprintf("  Refrigerated: %d samples (%.1f%%)\n",
              n_refrig, 100 * n_refrig / chunk$n_samples))
  cat("\n")
  
  # Emissions by type
  if (n_dry > 0) {
    dry_mean <- mean(chunk$results$co2_emissions_kg[!chunk$results$is_refrigerated])
    cat(sprintf("  Dry mean CO2: %.2f kg\n", dry_mean))
  }
  
  if (n_refrig > 0) {
    refrig_mean <- mean(chunk$results$co2_emissions_kg[chunk$results$is_refrigerated])
    cat(sprintf("  Refrigerated mean CO2: %.2f kg\n", refrig_mean))
  }
  
  cat("\n")
  
  invisible(NULL)
}


#' Validate Contribution Artifact
#'
#' Validates a contribution artifact against the JSON schema.
#'
#' @param artifact_path Path to the contribution artifact JSON file.
#' @param schema_path Optional path to schema. If NULL, uses package schema.
#'
#' @return TRUE if valid, FALSE otherwise. Prints validation messages.
#'
#' @export
#' @examples
#' \dontrun{
#' validate_contribution_artifact("outputs/contribution_artifact.json")
#' }
validate_contribution_artifact <- function(artifact_path, schema_path = NULL) {
  
  if (!file.exists(artifact_path)) {
    stop(sprintf("Artifact file not found: %s", artifact_path))
  }
  
  # Load artifact
  artifact <- jsonlite::read_json(artifact_path, simplifyVector = FALSE)
  
  # Basic checks (schema validation would require additional package)
  required_fields <- c(
    "simulation_id", "timestamp", "parameters", "base_seed",
    "n_chunks", "chunk_size", "total_samples", 
    "summary_statistics", "reproducibility_hash"
  )
  
  missing <- setdiff(required_fields, names(artifact))
  
  if (length(missing) > 0) {
    cat("Validation FAILED: Missing required fields:\n")
    cat(paste("  -", missing, collapse = "\n"), "\n")
    return(FALSE)
  }
  
  # Check simulation_id format (MD5 hash)
  if (!grepl("^[a-f0-9]{32}$", artifact$simulation_id)) {
    cat("Warning: simulation_id does not match MD5 format\n")
  }
  
  # Check reproducibility_hash format
  if (!grepl("^[a-f0-9]{32}$", artifact$reproducibility_hash)) {
    cat("Warning: reproducibility_hash does not match MD5 format\n")
  }
  
  # Check parameter ranges
  params <- artifact$parameters
  param_checks <- list(
    distance_mean = c(0, 10000),
    payload_mean = c(0, 50),
    temp_mean = c(-40, 50),
    fuel_efficiency_mean = c(10, 100),
    refrigeration_prob = c(0, 1)
  )
  
  for (param_name in names(param_checks)) {
    if (param_name %in% names(params)) {
      value <- params[[param_name]]
      range <- param_checks[[param_name]]
      if (value < range[1] || value > range[2]) {
        cat(sprintf("Warning: %s = %g is outside expected range [%g, %g]\n",
                    param_name, value, range[1], range[2]))
      }
    }
  }
  
  cat("Validation PASSED: All required fields present\n")
  cat(sprintf("Simulation ID: %s\n", artifact$simulation_id))
  cat(sprintf("Total samples: %s\n", format(artifact$total_samples, big.mark = ",")))
  cat(sprintf("Timestamp: %s\n", artifact$timestamp))
  
  return(TRUE)
}


#' Compare Two Simulation Results
#'
#' Compares statistical results from two simulations.
#'
#' @param result1 First simulation result (merged moments).
#' @param result2 Second simulation result (merged moments).
#' @param label1 Label for first result (default: "Result 1").
#' @param label2 Label for second result (default: "Result 2").
#'
#' @return NULL (invisibly). Prints comparison to console.
#'
#' @export
#' @examples
#' \dontrun{
#' compare_simulations(merged1, merged2, "Scenario A", "Scenario B")
#' }
compare_simulations <- function(result1, result2, 
                                label1 = "Result 1", 
                                label2 = "Result 2") {
  
  cat("=== Simulation Comparison ===\n\n")
  
  cat(sprintf("%-20s %15s %15s %15s\n", 
              "Statistic", label1, label2, "Difference"))
  cat(strrep("-", 68), "\n")
  
  # Sample size
  cat(sprintf("%-20s %15s %15s %15s\n",
              "Sample Size",
              format(result1$n, big.mark = ","),
              format(result2$n, big.mark = ","),
              format(result2$n - result1$n, big.mark = ",")))
  
  # Mean
  diff_mean <- result2$mean - result1$mean
  pct_mean <- 100 * diff_mean / result1$mean
  cat(sprintf("%-20s %15.2f %15.2f %14.2f%%\n",
              "Mean CO2 (kg)",
              result1$mean, result2$mean, pct_mean))
  
  # SD
  sd1 <- sqrt(result1$variance)
  sd2 <- sqrt(result2$variance)
  diff_sd <- sd2 - sd1
  pct_sd <- 100 * diff_sd / sd1
  cat(sprintf("%-20s %15.2f %15.2f %14.2f%%\n",
              "SD (kg)",
              sd1, sd2, pct_sd))
  
  # Variance
  diff_var <- result2$variance - result1$variance
  pct_var <- 100 * diff_var / result1$variance
  cat(sprintf("%-20s %15.2f %15.2f %14.2f%%\n",
              "Variance",
              result1$variance, result2$variance, pct_var))
  
  # Skewness
  if (!is.na(result1$skewness) && !is.na(result2$skewness)) {
    diff_skew <- result2$skewness - result1$skewness
    cat(sprintf("%-20s %15.3f %15.3f %15.3f\n",
                "Skewness",
                result1$skewness, result2$skewness, diff_skew))
  }
  
  # Kurtosis
  if (!is.na(result1$kurtosis) && !is.na(result2$kurtosis)) {
    diff_kurt <- result2$kurtosis - result1$kurtosis
    cat(sprintf("%-20s %15.3f %15.3f %15.3f\n",
                "Kurtosis",
                result1$kurtosis, result2$kurtosis, diff_kurt))
  }
  
  cat("\n")
  
  invisible(NULL)
}
