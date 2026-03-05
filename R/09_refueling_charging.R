# Refuel/charge service-time helpers.

resolve_service_time_hours <- function(powertrain, service_minutes) {
  if (!is.finite(service_minutes)) return(0)
  mins <- max(0, as.numeric(service_minutes))
  mins / 60
}

resolve_vehicle_range_km <- function(powertrain, truck_params_df = NULL) {
  if (is.null(truck_params_df)) {
    path <- file.path("data", "truck_parameters.csv")
    if (!file.exists(path)) return(NA_real_)
    truck_params_df <- utils::read.csv(path, stringsAsFactors = FALSE)
  }
  key <- if (tolower(as.character(powertrain)) == "bev") "bev" else "diesel"
  d <- truck_params_df[tolower(truck_params_df$powertrain) == key, , drop = FALSE]
  if (nrow(d) == 0) return(NA_real_)
  mean(c(as.numeric(d$range_km_low[[1]]), as.numeric(d$range_km_high[[1]])), na.rm = TRUE)
}
