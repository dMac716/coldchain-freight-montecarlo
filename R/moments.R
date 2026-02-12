#' Merge Moments from Multiple Chunks
#'
#' Merges exact statistical moments from multiple Monte Carlo chunks using
#' parallel axis theorem and other exact combination formulas.
#'
#' @param moments_list List of moment objects from different chunks.
#'
#' @return A merged moment object with combined statistics.
#'
#' @details
#' Uses exact formulas for combining means, variances, and higher moments
#' from independent samples. This is more accurate than recalculating from
#' pooled raw data.
#'
#' @export
#' @examples
#' # Assuming moments_list contains moment objects from chunks
#' # merged <- merge_moments(moments_list)
merge_moments <- function(moments_list) {
  
  if (length(moments_list) == 0) {
    stop("Cannot merge empty moments list")
  }
  
  # Filter out empty moments
  moments_list <- Filter(function(m) m$n > 0, moments_list)
  
  if (length(moments_list) == 0) {
    return(list(n = 0, mean = NA, variance = NA, skewness = NA, kurtosis = NA))
  }
  
  if (length(moments_list) == 1) {
    return(moments_list[[1]])
  }
  
  # Extract components
  ns <- sapply(moments_list, function(m) m$n)
  means <- sapply(moments_list, function(m) m$mean)
  
  # Total sample size
  n_total <- sum(ns)
  
  # Combined mean (weighted average)
  mean_total <- sum(ns * means) / n_total
  
  # Combined variance using parallel axis theorem
  # Var(X) = E[X^2] - E[X]^2
  # For combined samples: need to account for deviation of group means from overall mean
  
  m2_total <- 0
  m3_total <- 0
  m4_total <- 0
  
  for (i in seq_along(moments_list)) {
    m <- moments_list[[i]]
    n_i <- m$n
    mean_i <- m$mean
    delta <- mean_i - mean_total
    
    # Second moment
    m2_total <- m2_total + n_i * (m$m2 + delta^2)
    
    # Third moment (if available)
    if (!is.null(m$m3) && !is.na(m$m3)) {
      m3_total <- m3_total + n_i * (m$m3 + 3 * m$m2 * delta + delta^3)
    }
    
    # Fourth moment (if available)
    if (!is.null(m$m4) && !is.na(m$m4)) {
      m4_total <- m4_total + n_i * (m$m4 + 4 * m$m3 * delta + 
                                      6 * m$m2 * delta^2 + delta^4)
    }
  }
  
  m2_total <- m2_total / n_total
  m3_total <- m3_total / n_total
  m4_total <- m4_total / n_total
  
  # Calculate derived statistics
  variance_total <- m2_total * n_total / (n_total - 1)
  
  if (m2_total > 0) {
    skewness_total <- m3_total / (m2_total^(3/2))
    kurtosis_total <- m4_total / (m2_total^2) - 3
  } else {
    skewness_total <- NA
    kurtosis_total <- NA
  }
  
  return(list(
    n = n_total,
    mean = mean_total,
    variance = variance_total,
    m2 = m2_total,
    m3 = m3_total,
    m4 = m4_total,
    skewness = skewness_total,
    kurtosis = kurtosis_total,
    sd = sqrt(variance_total)
  ))
}
