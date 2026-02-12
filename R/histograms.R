#' Create Histogram
#'
#' Creates a histogram with specified breaks for mergeable aggregation.
#'
#' @param values Numeric vector of values.
#' @param type Character. Type label for the histogram.
#' @param breaks Numeric. Number of breaks or vector of break points.
#'
#' @return A list representing the histogram with counts, breaks, and type.
#'
#' @export
#' @examples
#' values <- rnorm(1000, 100, 20)
#' hist <- create_histogram(values, "test")
create_histogram <- function(values, type, breaks = 50) {
  
  if (length(values) == 0) {
    return(list(
      type = type,
      n = 0,
      breaks = numeric(0),
      counts = integer(0),
      density = numeric(0)
    ))
  }
  
  # Create histogram
  h <- hist(values, breaks = breaks, plot = FALSE)
  
  return(list(
    type = type,
    n = length(values),
    breaks = h$breaks,
    counts = as.integer(h$counts),
    density = h$density,
    mids = h$mids
  ))
}


#' Merge Histograms
#'
#' Merges multiple histograms with identical break points.
#'
#' @param hist_list List of histogram objects to merge.
#'
#' @return A merged histogram object.
#'
#' @export
#' @examples
#' h1 <- create_histogram(rnorm(100), "test")
#' h2 <- create_histogram(rnorm(100), "test")
#' merged <- merge_histograms(list(h1, h2))
merge_histograms <- function(hist_list) {
  
  if (length(hist_list) == 0) {
    stop("Cannot merge empty histogram list")
  }
  
  # Filter out empty histograms
  hist_list <- Filter(function(h) h$n > 0, hist_list)
  
  if (length(hist_list) == 0) {
    return(hist_list[[1]])
  }
  
  # Use the first histogram as template
  template <- hist_list[[1]]
  
  # Check that all histograms have compatible breaks
  breaks <- template$breaks
  for (h in hist_list[-1]) {
    if (!all.equal(h$breaks, breaks)) {
      # Try to rebin to common breaks
      warning("Histograms have different breaks, results may be approximate")
    }
  }
  
  # Sum counts across histograms
  total_counts <- template$counts
  total_n <- template$n
  
  for (h in hist_list[-1]) {
    if (length(h$counts) == length(total_counts)) {
      total_counts <- total_counts + h$counts
      total_n <- total_n + h$n
    }
  }
  
  # Recalculate density
  bin_widths <- diff(breaks)
  total_density <- total_counts / (total_n * bin_widths)
  
  return(list(
    type = template$type,
    n = total_n,
    breaks = breaks,
    counts = total_counts,
    density = total_density,
    mids = template$mids
  ))
}


#' Aggregate Histograms
#'
#' Aggregates histograms from multiple Monte Carlo chunks.
#'
#' @param chunks List of chunk results, each containing histogram data.
#' @param type Character. Which histogram to aggregate ("dry" or "refrigerated").
#'
#' @return An aggregated histogram.
#'
#' @export
#' @examples
#' # Assuming chunks is a list of chunk results
#' # agg_hist <- aggregate_histograms(chunks, "dry")
aggregate_histograms <- function(chunks, type = c("dry", "refrigerated")) {
  
  type <- match.arg(type)
  
  # Extract histograms of the specified type
  hist_field <- paste0("histogram_", type)
  
  hist_list <- lapply(chunks, function(chunk) {
    chunk[[hist_field]]
  })
  
  # Merge all histograms
  merged <- merge_histograms(hist_list)
  
  return(merged)
}
