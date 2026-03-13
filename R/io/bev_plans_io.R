# Offline BEV route plans loader/validator.

`%||%` <- function(x, y) if (!is.null(x)) x else y

parse_waypoint_station_ids <- function(x) {
  s <- trimws(as.character(x %||% ""))
  if (!nzchar(s)) return(character())
  if (grepl("^\\[", s)) {
    if (requireNamespace("jsonlite", quietly = TRUE)) {
      v <- tryCatch(jsonlite::fromJSON(s), error = function(e) NULL)
      if (!is.null(v)) return(as.character(unlist(v, use.names = FALSE)))
    }
    s <- gsub("[\\[\\]\"]", "", s)
  }
  out <- strsplit(s, "[|;,]", perl = TRUE)[[1]]
  out <- trimws(out)
  out[nzchar(out)]
}

read_bev_route_plans <- function(path) {
  if (!file.exists(path)) stop("BEV route plans file missing: ", path)
  d <- utils::read.csv(path, stringsAsFactors = FALSE)
  req <- c("route_plan_id", "route_id", "facility_id", "retail_id", "waypoint_station_ids")
  miss <- setdiff(req, names(d))
  if (length(miss) > 0) stop("BEV plans missing columns: ", paste(miss, collapse = ", "))
  d$waypoint_station_ids_vec <- I(lapply(d$waypoint_station_ids, parse_waypoint_station_ids))
  d
}
