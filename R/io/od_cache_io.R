# Offline OD cache loader for optional stop-to-stop detour modeling.

read_od_cache <- function(path) {
  if (!file.exists(path)) stop("OD cache file missing: ", path)
  d <- utils::read.csv(path, stringsAsFactors = FALSE)
  req <- c("origin_id", "dest_id", "road_distance_miles", "road_duration_minutes")
  miss <- setdiff(req, names(d))
  if (length(miss) > 0) stop("OD cache missing columns: ", paste(miss, collapse = ", "))
  d
}

lookup_od_cache <- function(od_df, origin_id, dest_id) {
  hit <- od_df[od_df$origin_id == origin_id & od_df$dest_id == dest_id, , drop = FALSE]
  if (nrow(hit) == 0) return(NULL)
  hit[1, , drop = FALSE]
}
