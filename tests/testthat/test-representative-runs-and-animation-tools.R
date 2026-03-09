test_that("select_representative_runs chooses one diesel and one bev", {
  td <- tempfile("rep_runs_")
  dir.create(td, recursive = TRUE)
  runs_csv <- file.path(td, "runs.csv")
  out_csv <- file.path(td, "rep.csv")

  d <- data.frame(
    run_id = c("d1","d2","b1","b2"),
    powertrain = c("diesel","diesel","bev","bev"),
    status = c("OK","OK","OK","OK"),
    co2_per_1000kcal = c(0.15,0.20,0.09,0.13),
    delivery_time_min = c(90,120,95,130),
    stringsAsFactors = FALSE
  )
  utils::write.csv(d, runs_csv, row.names = FALSE)

  repo_root <- normalizePath(file.path("..", ".."), winslash = "/", mustWork = TRUE)
  status <- system2("Rscript", c(file.path(repo_root, "tools", "select_representative_runs.R"), "--runs_csv", runs_csv, "--out_csv", out_csv), stdout = TRUE, stderr = TRUE)
  expect_true(is.null(attr(status, "status")) || identical(attr(status, "status"), 0L))
  out <- utils::read.csv(out_csv, stringsAsFactors = FALSE)
  expect_true(all(c("diesel", "bev") %in% tolower(out$powertrain)))
})

python_has_plot_stack <- function() {
  py <- Sys.which("python3")
  if (!nzchar(py)) return(FALSE)
  code <- paste(
    "import importlib.util,sys",
    "mods=['numpy','pandas','matplotlib']",
    "ok=all(importlib.util.find_spec(m) is not None for m in mods)",
    "sys.exit(0 if ok else 1)",
    sep = ";"
  )
  st <- suppressWarnings(system2(py, c("-c", shQuote(code)), stdout = FALSE, stderr = FALSE))
  identical(as.integer(st), 0L)
}

test_that("generate_route_animation preflight exits cleanly on missing representative ids", {
  if (!python_has_plot_stack()) skip("python plot stack unavailable")
  td <- tempfile("anim_preflight_")
  dir.create(td, recursive = TRUE)
  rep_csv <- file.path(td, "rep.csv")
  utils::write.csv(data.frame(run_id = c("missing_d", "missing_b"), powertrain = c("diesel", "bev")), rep_csv, row.names = FALSE)

  repo_root <- normalizePath(file.path("..", ".."), winslash = "/", mustWork = TRUE)
  py <- Sys.which("python3")
  out <- system2(py,
    c(file.path(repo_root, "tools", "generate_route_animation.py"),
      "--representative_csv", rep_csv,
      "--tracks_dir", file.path(td, "tracks"),
      "--outdir", file.path(td, "anim")),
    stdout = TRUE, stderr = TRUE)
  status <- attr(out, "status")
  expect_false(is.null(status))
  expect_true(as.integer(status) != 0L)
})

test_that("select_representative_runs prefers refrigerated rows when matched options exist", {
  td <- tempfile("rep_runs_refrigerated_pref_")
  dir.create(td, recursive = TRUE)
  runs_csv <- file.path(td, "runs.csv")
  out_csv <- file.path(td, "rep.csv")

  # Two matched-route candidates per powertrain (dry + refrigerated). The selector
  # should choose refrigerated when both are available for the same matched group.
  d <- data.frame(
    run_id = c(
      "DISTRIBUTION_DAVIS_diesel_dry_factory_set_stochastic_1",
      "DISTRIBUTION_DAVIS_diesel_refrigerated_factory_set_stochastic_1",
      "DISTRIBUTION_DAVIS_bev_dry_factory_set_stochastic_1",
      "DISTRIBUTION_DAVIS_bev_refrigerated_factory_set_stochastic_1"
    ),
    powertrain = c("diesel", "diesel", "bev", "bev"),
    status = c("OK", "OK", "OK", "OK"),
    co2_per_1000kcal = c(0.10, 0.11, 0.08, 0.09),
    delivery_time_min = c(100, 102, 98, 101),
    scenario = c("DISTRIBUTION_DAVIS", "DISTRIBUTION_DAVIS", "DISTRIBUTION_DAVIS", "DISTRIBUTION_DAVIS"),
    origin_network = c("refrigerated_factory_set", "refrigerated_factory_set", "refrigerated_factory_set", "refrigerated_factory_set"),
    traffic_mode = c("stochastic", "stochastic", "stochastic", "stochastic"),
    route_id = c("route_r", "route_r", "route_r", "route_r"),
    product_type = c("dry", "refrigerated", "dry", "refrigerated"),
    stringsAsFactors = FALSE
  )
  utils::write.csv(d, runs_csv, row.names = FALSE)

  repo_root <- normalizePath(file.path("..", ".."), winslash = "/", mustWork = TRUE)
  status <- system2(
    "Rscript",
    c(
      file.path(repo_root, "tools", "select_representative_runs.R"),
      "--runs_csv", runs_csv,
      "--out_csv", out_csv,
      "--require_matched_route", "true",
      "--require_track_files", "false"
    ),
    stdout = TRUE,
    stderr = TRUE
  )
  expect_true(is.null(attr(status, "status")) || identical(attr(status, "status"), 0L))

  out <- utils::read.csv(out_csv, stringsAsFactors = FALSE)
  expect_equal(nrow(out), 2)
  expect_true(all(grepl("refrigerated", tolower(out$run_id), fixed = TRUE)))
})
