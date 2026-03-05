# Trip-time rollup helpers.

compute_trip_time_rollup <- function(driving_h, traffic_delay_h, service_h, rest_h) {
  driving_h <- as.numeric(driving_h %||% 0)
  traffic_delay_h <- as.numeric(traffic_delay_h %||% 0)
  service_h <- as.numeric(service_h %||% 0)
  rest_h <- as.numeric(rest_h %||% 0)
  total_h <- driving_h + traffic_delay_h + service_h + rest_h
  list(
    driver_time_total_h = total_h,
    driving_time_h = driving_h,
    traffic_delay_time_h = traffic_delay_h,
    service_time_h = service_h,
    rest_time_h = rest_h,
    trip_duration_h = total_h
  )
}
