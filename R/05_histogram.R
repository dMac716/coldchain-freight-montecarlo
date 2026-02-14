build_hist_edges <- function(hist_config) {
  validate_hist_config(hist_config)
  edges <- list()
  for (i in seq_along(hist_config$metric)) {
    edges[[hist_config$metric[i]]] <- seq(
      hist_config$min[i],
      hist_config$max[i],
      length.out = hist_config$bins[i] + 1
    )
  }
  edges
}

make_histogram <- function(x, bin_edges) {
  x <- x[is.finite(x)]
  bin_edges <- as.numeric(bin_edges)
  if (length(bin_edges) < 2) stop("bin_edges must have length >= 2")

  idx <- findInterval(x, bin_edges, rightmost.closed = FALSE, all.inside = FALSE)
  underflow <- sum(idx == 0)
  overflow <- sum(idx == length(bin_edges))
  in_bin <- idx[idx >= 1 & idx < length(bin_edges)]
  counts <- tabulate(in_bin, nbins = length(bin_edges) - 1)

  list(
    bin_edges = bin_edges,
    counts = counts,
    underflow = underflow,
    overflow = overflow
  )
}

merge_histograms <- function(hist_list) {
  if (length(hist_list) == 0) stop("hist_list must be non-empty.")
  base_edges <- hist_list[[1]]$bin_edges
  for (h in hist_list) {
    if (!isTRUE(all.equal(base_edges, h$bin_edges))) {
      stop("Histogram bin edges do not match.")
    }
  }

  counts <- Reduce(`+`, lapply(hist_list, function(h) h$counts))
  underflow <- sum(vapply(hist_list, function(h) h$underflow, numeric(1)))
  overflow <- sum(vapply(hist_list, function(h) h$overflow, numeric(1)))

  list(
    bin_edges = base_edges,
    counts = counts,
    underflow = underflow,
    overflow = overflow
  )
}

hist_quantile <- function(hist, p) {
  if (p < 0 || p > 1) stop("p must be in [0,1]")

  counts <- hist$counts
  edges <- hist$bin_edges
  n_total <- sum(counts) + hist$underflow + hist$overflow
  if (n_total == 0) return(NA_real_)

  target <- p * n_total
  if (target <= hist$underflow) return(edges[1])
  if (target >= n_total - hist$overflow) return(edges[length(edges)])

  cum <- hist$underflow + cumsum(counts)
  idx <- which(cum >= target)[1]
  prev <- if (idx == 1) hist$underflow else cum[idx - 1]
  count <- counts[idx]
  if (count == 0) return(edges[idx])
  frac <- (target - prev) / count
  edges[idx] + frac * (edges[idx + 1] - edges[idx])
}

hist_summary <- function(hist) {
  list(
    p05 = hist_quantile(hist, 0.05),
    p50 = hist_quantile(hist, 0.50),
    p95 = hist_quantile(hist, 0.95)
  )
}
