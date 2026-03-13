# Offline route geometry loader/validator.

read_route_geometries <- function(path) {
  if (!file.exists(path)) stop("Route geometries file missing: ", path)
  d <- utils::read.csv(path, stringsAsFactors = FALSE)
  req <- c("route_id", "facility_id", "retail_id", "distance_m", "duration_s", "encoded_polyline")
  miss <- setdiff(req, names(d))
  if (length(miss) > 0) stop("Route geometries missing columns: ", paste(miss, collapse = ", "))
  if (any(!nzchar(as.character(d$encoded_polyline)))) stop("Empty encoded_polyline found in routes file")

  if ("route_rank" %in% names(d)) {
    d <- d[order(d$route_id, d$route_rank), , drop = FALSE]
    keep <- !duplicated(d$route_id)
    d <- d[keep, , drop = FALSE]
  } else {
    d <- d[!duplicated(d$route_id), , drop = FALSE]
  }
  d
}
