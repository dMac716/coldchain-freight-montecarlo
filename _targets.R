library(targets)
library(tarchetypes)
library(coldchainfreight)

# Source functions if needed
# tar_source()

# Set target-specific options such as packages
tar_option_set(
  packages = c("coldchainfreight", "jsonlite"),
  format = "rds"
)

# Define simulation parameters
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

# Configuration
n_total_samples <- 10000
chunk_size <- 1000
n_chunks <- ceiling(n_total_samples / chunk_size)
base_seed <- 42

list(
  # Initialize reproducibility log
  tar_target(
    log_file,
    {
      log_path <- "outputs/reproducibility_log.json"
      dir.create("outputs", showWarnings = FALSE, recursive = TRUE)
      init_reproducibility_log(log_path, overwrite = TRUE)
      log_path
    }
  ),
  
  # Define chunk IDs and seeds
  tar_target(
    chunk_ids,
    seq_len(n_chunks)
  ),
  
  tar_target(
    chunk_seeds,
    base_seed + (seq_len(n_chunks) - 1) * 1000
  ),
  
  # Run Monte Carlo chunks in parallel
  tar_target(
    mc_chunks,
    {
      # Ensure log is initialized
      options(coldchainfreight.log_file = log_file)
      
      run_mc_chunk(
        chunk_id = chunk_ids,
        chunk_size = chunk_size,
        seed = chunk_seeds,
        params = params
      )
    },
    pattern = map(chunk_ids, chunk_seeds)
  ),
  
  # Merge all moments
  tar_target(
    merged_moments,
    {
      moments_list <- lapply(mc_chunks, function(chunk) chunk$moments)
      merge_moments(moments_list)
    }
  ),
  
  # Aggregate histograms
  tar_target(
    histogram_dry,
    aggregate_histograms(mc_chunks, "dry")
  ),
  
  tar_target(
    histogram_refrigerated,
    aggregate_histograms(mc_chunks, "refrigerated")
  ),
  
  # Combine all results
  tar_target(
    combined_results,
    {
      do.call(rbind, lapply(mc_chunks, function(chunk) chunk$results))
    }
  ),
  
  # Summary statistics
  tar_target(
    summary_stats,
    {
      list(
        total_samples = nrow(combined_results),
        n_dry = sum(!combined_results$is_refrigerated),
        n_refrigerated = sum(combined_results$is_refrigerated),
        
        # Overall statistics
        overall_mean_co2 = merged_moments$mean,
        overall_sd_co2 = merged_moments$sd,
        overall_variance = merged_moments$variance,
        
        # Dry freight statistics
        dry_mean_co2 = mean(combined_results$co2_emissions_kg[!combined_results$is_refrigerated]),
        dry_sd_co2 = sd(combined_results$co2_emissions_kg[!combined_results$is_refrigerated]),
        
        # Refrigerated freight statistics
        refrig_mean_co2 = mean(combined_results$co2_emissions_kg[combined_results$is_refrigerated]),
        refrig_sd_co2 = sd(combined_results$co2_emissions_kg[combined_results$is_refrigerated]),
        
        # Cost comparison
        dry_mean_cost = mean(combined_results$total_cost_usd[!combined_results$is_refrigerated]),
        refrig_mean_cost = mean(combined_results$total_cost_usd[combined_results$is_refrigerated]),
        cost_difference = mean(combined_results$total_cost_usd[combined_results$is_refrigerated]) - 
                         mean(combined_results$total_cost_usd[!combined_results$is_refrigerated])
      )
    }
  ),
  
  # Save results
  tar_target(
    save_results,
    {
      dir.create("outputs", showWarnings = FALSE, recursive = TRUE)
      
      # Save summary
      saveRDS(summary_stats, "outputs/summary_stats.rds")
      
      # Save histograms
      saveRDS(histogram_dry, "outputs/histogram_dry.rds")
      saveRDS(histogram_refrigerated, "outputs/histogram_refrigerated.rds")
      
      # Save merged moments
      saveRDS(merged_moments, "outputs/merged_moments.rds")
      
      # Save combined results (sample)
      saveRDS(combined_results, "outputs/combined_results.rds")
      
      # Create contribution artifact JSON
      artifact <- list(
        simulation_id = digest::digest(list(params, base_seed), algo = "md5"),
        timestamp = as.character(Sys.time()),
        parameters = params,
        base_seed = base_seed,
        n_chunks = n_chunks,
        chunk_size = chunk_size,
        total_samples = n_total_samples,
        summary_statistics = summary_stats,
        reproducibility_hash = get_reproducibility_hash()
      )
      
      jsonlite::write_json(
        artifact,
        "outputs/contribution_artifact.json",
        pretty = TRUE,
        auto_unbox = TRUE
      )
      
      "outputs"
    }
  ),
  
  # Render report
  tar_quarto(
    report,
    path = "inst/quarto/simulation_report.qmd",
    working_directory = getwd()
  )
)
