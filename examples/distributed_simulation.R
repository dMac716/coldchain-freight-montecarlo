# Example: Distributed Simulation Setup
# This script shows how to set up a distributed simulation across multiple nodes

library(coldchainfreight)

cat("=== Distributed Simulation Setup Guide ===\n\n")

# Simulation configuration
n_total_samples <- 100000  # Total samples desired
chunk_size <- 5000          # Samples per chunk
n_chunks <- ceiling(n_total_samples / chunk_size)

cat(sprintf("Target: %s samples\n", format(n_total_samples, big.mark = ",")))
cat(sprintf("Chunk size: %s samples\n", format(chunk_size, big.mark = ",")))
cat(sprintf("Number of chunks: %d\n\n", n_chunks))

# Parameters for the simulation
params <- list(
  distance_mean = 500,
  distance_sd = 100,
  payload_mean = 20,
  payload_sd = 5,
  temp_mean = 20,
  temp_sd = 8,
  fuel_efficiency_mean = 30,
  fuel_efficiency_sd = 5,
  refrigeration_prob = 0.3
)

# Generate chunk specifications
base_seed <- 42
chunk_specs <- data.frame(
  chunk_id = 1:n_chunks,
  seed = base_seed + (1:n_chunks - 1) * 1000,
  chunk_size = chunk_size
)

cat("Chunk specifications:\n")
print(head(chunk_specs, 10))
if (n_chunks > 10) {
  cat(sprintf("... and %d more chunks\n", n_chunks - 10))
}

cat("\n=== Execution Strategy ===\n\n")

cat("Option 1: Local Sequential Execution\n")
cat("  - Use: for loop over chunk_specs\n")
cat("  - Pros: Simple, no setup required\n")
cat("  - Cons: Slow for large simulations\n\n")

cat("Option 2: Local Parallel (future)\n")
cat("  - Use: future::plan(multisession)\n")
cat("  - Code: future.apply::future_lapply()\n")
cat("  - Pros: Utilizes all CPU cores\n")
cat("  - Cons: Limited to one machine\n\n")

cat("Option 3: Cluster Parallel (targets + clustermq)\n")
cat("  - Use: targets::tar_make_clustermq()\n")
cat("  - Requires: clustermq package, job scheduler\n")
cat("  - Pros: True distributed computing\n")
cat("  - Cons: Requires HPC infrastructure\n\n")

cat("Option 4: Cloud Parallel (targets + future)\n")
cat("  - Use: targets::tar_make_future() with cloud workers\n")
cat("  - Pros: Scalable, no local HPC needed\n")
cat("  - Cons: Requires cloud setup and costs\n\n")

# Example: Sequential execution of first 3 chunks
cat("=== Demo: Sequential Execution (3 chunks) ===\n\n")

# Initialize log
init_reproducibility_log("distributed_demo_log.json", overwrite = TRUE)

results <- list()
for (i in 1:min(3, n_chunks)) {
  cat(sprintf("Executing chunk %d...\n", i))
  
  result <- run_mc_chunk(
    chunk_id = chunk_specs$chunk_id[i],
    chunk_size = chunk_specs$chunk_size[i],
    seed = chunk_specs$seed[i],
    params = params
  )
  
  results[[i]] <- result
  cat(sprintf("  Completed. Mean: %.2f, SD: %.2f\n",
              result$moments$mean,
              sqrt(result$moments$variance)))
}

# Merge results
cat("\nMerging results...\n")
moments_list <- lapply(results, function(r) r$moments)
merged <- merge_moments(moments_list)

cat(sprintf("Merged statistics (n=%d):\n", merged$n))
cat(sprintf("  Mean: %.2f kg CO2\n", merged$mean))
cat(sprintf("  SD: %.2f kg CO2\n", merged$sd))

cat("\n=== Aggregation Workflow ===\n\n")

cat("After running all chunks (potentially on different nodes):\n\n")
cat("1. Collect all chunk results\n")
cat("2. Merge moments: merge_moments(list(chunk1$moments, chunk2$moments, ...))\n")
cat("3. Aggregate histograms: aggregate_histograms(chunks, 'dry')\n")
cat("4. Combine data frames: do.call(rbind, lapply(chunks, function(c) c$results))\n")
cat("5. Save aggregated results\n")
cat("6. Generate final report\n")

cat("\n=== Key Benefits of This Approach ===\n\n")

cat("✓ Each chunk is completely independent\n")
cat("✓ Chunks can run in parallel on different machines\n")
cat("✓ Results merge exactly (not approximately)\n")
cat("✓ No need to transfer large datasets\n")
cat("✓ Fully reproducible with explicit seeds\n")
cat("✓ Can resume if some chunks fail\n")
cat("✓ Scales to billions of samples\n")

# Clean up
file.remove("distributed_demo_log.json")
