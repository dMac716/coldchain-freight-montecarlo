test_that("export_hero_run creates event log and geojson artifacts", {
  td <- tempfile("hero_")
  dir.create(td, recursive = TRUE)
  bundle_root <- file.path(td, "run_bundle")
  outdir <- file.path(td, "hero_out")
  bd <- file.path(bundle_root, "run_x")
  dir.create(bd, recursive = TRUE)

  jsonlite::write_json(list(
    run_id = "run_x",
    scenario = "SCEN_HERO",
    seed = 777,
    powertrain = "bev"
  ), file.path(bd, "params.json"), auto_unbox = TRUE, pretty = TRUE)

  events <- data.frame(
    t_start = c("2026-03-05 00:00:00 UTC", "2026-03-05 01:00:00 UTC"),
    t_end = c("2026-03-05 00:10:00 UTC", "2026-03-05 01:05:00 UTC"),
    event_type = c("DEPART_DEPOT", "ROUTE_COMPLETE"),
    lat = c(38.50, 38.55),
    lng = c(-121.80, -121.70),
    energy_delta_kwh = c(0, 0),
    fuel_delta_gal = c(0, 0),
    co2_delta_kg = c(0, 0),
    reason = c("start", "done"),
    stringsAsFactors = FALSE
  )
  utils::write.csv(events, file.path(bd, "events.csv"), row.names = FALSE)

  tracks <- data.frame(
    t = c("2026-03-05 00:00:00 UTC", "2026-03-05 00:30:00 UTC", "2026-03-05 01:00:00 UTC"),
    lat = c(38.50, 38.52, 38.55),
    lng = c(-121.80, -121.75, -121.70),
    co2_kg_cum = c(0, 10, 20),
    distance_miles_cum = c(0, 30, 60),
    trip_duration_h_cum = c(0, 0.5, 1.0),
    soc = c(0.9, 0.8, 0.7),
    fuel_gal = c(NA, NA, NA),
    stringsAsFactors = FALSE
  )
  gz <- gzfile(file.path(bd, "tracks.csv.gz"), "wt")
  utils::write.csv(tracks, gz, row.names = FALSE)
  close(gz)

  cmd <- c(
    file.path("..", "..", "tools", "export_hero_run.R"),
    "--bundle_dir", bundle_root,
    "--scenario", "SCEN_HERO",
    "--seed", "777",
    "--outdir", outdir
  )
  status <- system2("Rscript", cmd, stdout = TRUE, stderr = TRUE)
  expect_true(is.null(attr(status, "status")) || identical(attr(status, "status"), 0L))

  expect_true(file.exists(file.path(outdir, "hero_event_log.csv")))
  expect_true(file.exists(file.path(outdir, "hero_route_line.geojson")))
  expect_true(file.exists(file.path(outdir, "hero_route_stops.geojson")))

  hero <- utils::read.csv(file.path(outdir, "hero_event_log.csv"), stringsAsFactors = FALSE)
  expect_true(all(c("time_min", "lat", "lon", "event_type", "stop_type", "soc_or_fuel", "co2_cum", "miles_cum", "driver_clock") %in% names(hero)))
  expect_equal(nrow(hero), 2)
})
