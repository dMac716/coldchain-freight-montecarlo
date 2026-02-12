#' Validate Input Parameters
#'
#' Validates input parameters for emission calculations to ensure they are
#' within acceptable ranges.
#'
#' @param inputs List of named parameters to validate.
#'
#' @return NULL if validation passes, stops with error message otherwise.
#'
#' @export
#' @examples
#' validate_inputs(list(distance_km = 500, payload_tons = 20))
validate_inputs <- function(inputs) {
  
  # Define validation rules
  rules <- list(
    distance_km = list(min = 0, max = 10000, type = "numeric"),
    payload_tons = list(min = 0, max = 50, type = "numeric"),
    ambient_temp_c = list(min = -40, max = 50, type = "numeric"),
    fuel_efficiency_l_per_100km = list(min = 10, max = 100, type = "numeric"),
    n_samples = list(min = 1, max = 1e9, type = "numeric"),
    chunk_size = list(min = 1, max = 1e7, type = "numeric")
  )
  
  for (name in names(inputs)) {
    value <- inputs[[name]]
    
    # Skip if no rule exists for this parameter
    if (!name %in% names(rules)) next
    
    rule <- rules[[name]]
    
    # Check type
    if (rule$type == "numeric") {
      if (!is.numeric(value) || length(value) != 1) {
        stop(sprintf("Parameter '%s' must be a single numeric value", name))
      }
      if (is.na(value) || !is.finite(value)) {
        stop(sprintf("Parameter '%s' must be finite (not NA, NaN, or Inf)", name))
      }
    }
    
    # Check range
    if (!is.null(rule$min) && value < rule$min) {
      stop(sprintf("Parameter '%s' must be >= %g (got %g)", name, rule$min, value))
    }
    if (!is.null(rule$max) && value > rule$max) {
      stop(sprintf("Parameter '%s' must be <= %g (got %g)", name, rule$max, value))
    }
  }
  
  invisible(NULL)
}
