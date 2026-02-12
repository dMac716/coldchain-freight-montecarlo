# Example: Monte Carlo Simulation
# This script demonstrates running a Monte Carlo simulation with multiple chunks

library(coldchainfreight)

# Set up simulation parameters
params <- list(
  distance_mean = 500,
  distance_sd = 100,
  payload_mean = 20,
  payload_sd = 5,
  temp_mean = 22,
  temp_sd = 8,
  fuel_efficiency_mean = 30,
  fuel_efficiency_sd = 5,
  refrigeration_prob = 0.3
)

# Initialize reproducibility log
log_file <- "example_simulation_log.json"
init_reproducibility_log(log_file, overwrite = TRUE)

cat("Running Monte Carlo simulation with 3 chunks...\n\n")

# Run multiple chunks
n_chunks <- 3
chunk_size <- 1000
base_seed <- 42

chunks <- list()
for (i in 1:n_chunks) {
  cat(sprintf("Running chunk %d/%d...\n", i, n_chunks))
  
  chunk <- run_mc_chunk(
    chunk_id = i,
    chunk_size = chunk_size,
    seed = base_seed + (i - 1) * 1000,
    params = params
  )
  
  chunks[[i]] <- chunk
  
  cat(sprintf("  Mean CO2: %.2f kg\n", chunk$moments$mean))
  cat(sprintf("  SD: %.2f kg\n", sqrt(chunk$moments$variance)))
}

cat("\n=== Merging Results ===\n")

# Merge moments
moments_list <- lapply(chunks, function(c) c$moments)
merged_moments <- merge_moments(moments_list)

cat(sprintf("Total samples: %d\n", merged_moments$n))
cat(sprintf("Overall mean CO2: %.2f kg\n", merged_moments$mean))
cat(sprintf("Overall SD: %.2f kg\n", merged_moments$sd))
cat(sprintf("Skewness: %.3f\n", merged_moments$skewness))
cat(sprintf("Kurtosis: %.3f\n", merged_moments$kurtosis))

# Aggregate histograms
cat("\n=== Aggregating Histograms ===\n")

hist_dry <- aggregate_histograms(chunks, "dry")
hist_refrig <- aggregate_histograms(chunks, "refrigerated")

cat(sprintf("Dry freight samples: %d\n", hist_dry$n))
cat(sprintf("Refrigerated samples: %d\n", hist_refrig$n))

# Compare means between dry and refrigerated
combined_results <- do.call(rbind, lapply(chunks, function(c) c$results))

dry_mean <- mean(combined_results$co2_emissions_kg[!combined_results$is_refrigerated])
refrig_mean <- mean(combined_results$co2_emissions_kg[combined_results$is_refrigerated])

cat(sprintf("\nDry mean: %.2f kg CO2\n", dry_mean))
cat(sprintf("Refrigerated mean: %.2f kg CO2\n", refrig_mean))
cat(sprintf("Difference: %.2f kg CO2 (%.1f%%)\n", 
            refrig_mean - dry_mean,
            100 * (refrig_mean / dry_mean - 1)))

# Plot histograms (if available)
if (requireNamespace("graphics", quietly = TRUE)) {
  cat("\n=== Generating Plots ===\n")
  
  # Simple histogram plot
  par(mfrow = c(1, 2))
  
  # Dry freight
  plot(hist_dry$mids, hist_dry$density, type = "l", lwd = 2, col = "blue",
       main = "Dry Freight CO2 Emissions",
       xlab = "CO2 Emissions (kg)", ylab = "Density")
  
  # Refrigerated freight
  plot(hist_refrig$mids, hist_refrig$density, type = "l", lwd = 2, col = "red",
       main = "Refrigerated Freight CO2 Emissions",
       xlab = "CO2 Emissions (kg)", ylab = "Density")
  
  cat("Plots generated.\n")
}

cat("\n=== Simulation Complete ===\n")
cat(sprintf("Reproducibility log saved to: %s\n", log_file))
cat(sprintf("Reproducibility hash: %s\n", get_reproducibility_hash()))

# Clean up
file.remove(log_file)
