#' Package: coldchainfreight
#'
#' @description
#' The coldchainfreight package provides tools for distributed Monte Carlo
#' simulation of freight emissions, comparing dry versus refrigerated transport.
#'
#' @section Main Functions:
#'
#' **Emission Calculations:**
#' \itemize{
#'   \item \code{\link{calculate_emissions}} - Deterministic emission model
#'   \item \code{\link{validate_inputs}} - Input validation
#' }
#'
#' **Monte Carlo Simulation:**
#' \itemize{
#'   \item \code{\link{run_mc_chunk}} - Run a simulation chunk
#'   \item \code{\link{merge_moments}} - Merge statistical moments
#'   \item \code{\link{aggregate_histograms}} - Aggregate histograms
#' }
#'
#' **Reproducibility:**
#' \itemize{
#'   \item \code{\link{init_reproducibility_log}} - Initialize logging
#'   \item \code{\link{log_event}} - Log simulation events
#'   \item \code{\link{get_reproducibility_hash}} - Get reproducibility hash
#' }
#'
#' @section Features:
#'
#' - Deterministic emission models
#' - Chunk-based distributed computing
#' - Exact statistical moment merging
#' - Mergeable histogram aggregation
#' - Comprehensive input validation
#' - Strict reproducibility logging
#' - Offline operation (no API calls)
#'
#' @section Workflow:
#'
#' 1. Define simulation parameters
#' 2. Initialize reproducibility log
#' 3. Run Monte Carlo chunks (parallel or distributed)
#' 4. Merge statistical moments
#' 5. Aggregate histograms
#' 6. Generate reports
#'
#' @docType package
#' @name coldchainfreight-package
#' @aliases coldchainfreight
#'
#' @examples
#' \dontrun{
#' # Basic usage
#' library(coldchainfreight)
#'
#' # Calculate emissions
#' result <- calculate_emissions(500, 20, FALSE, 20, 30)
#'
#' # Run Monte Carlo simulation
#' params <- list(
#'   distance_mean = 500, distance_sd = 100,
#'   payload_mean = 20, payload_sd = 5,
#'   temp_mean = 20, temp_sd = 8,
#'   fuel_efficiency_mean = 30, fuel_efficiency_sd = 5,
#'   refrigeration_prob = 0.3
#' )
#'
#' init_reproducibility_log("simulation.json")
#' chunk <- run_mc_chunk(1, 1000, 12345, params)
#'
#' # Use targets pipeline
#' targets::tar_make()
#' }
NULL
