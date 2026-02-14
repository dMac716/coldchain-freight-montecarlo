plot_histogram <- function(hist, main = "Histogram", xlab = "Value") {
  edges <- hist$bin_edges
  mids <- (edges[-1] + edges[-length(edges)]) / 2
  graphics::plot(
    mids,
    hist$counts,
    type = "h",
    main = main,
    xlab = xlab,
    ylab = "Count"
  )
  invisible(TRUE)
}
