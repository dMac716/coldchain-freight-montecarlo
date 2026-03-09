run_mc_once <- function(repo_root, td, scenario, powertrain, product_type, seed) {
  bundle_root <- file.path(td, paste(powertrain, product_type, sep = "_"))
  summary_out <- file.path(bundle_root, "route_sim_summary.csv")
  runs_out <- file.path(bundle_root, "route_sim_runs.csv")
  dir.create(bundle_root, recursive = TRUE, showWarnings = FALSE)
  cmd <- c(
    file.path(repo_root, "tools", "run_route_sim_mc.R"),
    "--config", file.path(repo_root, "test_kit.yaml"),
    "--scenario", scenario,
    "--scenario_id", paste0("test_", scenario, "_", powertrain, "_", product_type),
    "--powertrain", powertrain,
    "--product_type", product_type,
    "--traffic_mode", "freeflow",
    "--paired_origin_networks", "false",
    "--facility_id", "FACILITY_DRY_TOPEKA",
    "--n", "1",
    "--seed", as.character(seed),
    "--duration_hours", "24",
    "--artifact_mode", "full",
    "--bundle_root", bundle_root,
    "--summary_out", summary_out,
    "--runs_out", runs_out
  )
  out <- system2(
    "env",
    c(
      "OMP_NUM_THREADS=1",
      "OPENBLAS_NUM_THREADS=1",
      "MKL_NUM_THREADS=1",
      "VECLIB_MAXIMUM_THREADS=1",
      "R_DATATABLE_NUM_THREADS=1",
      "Rscript",
      cmd
    ),
    stdout = TRUE,
    stderr = TRUE
  )
  list(out = out, summary_out = summary_out, runs_out = runs_out)
}

test_that("reefer path is off for dry and on for refrigerated for diesel + bev", {
  routes_path <- file.path("..", "..", "data", "derived", "routes_facility_to_petco.csv")
  if (!file.exists(routes_path)) skip("routes cache missing for reefer-path test")
  routes <- utils::read.csv(routes_path, stringsAsFactors = FALSE)
  if (!("FACILITY_DRY_TOPEKA" %in% unique(as.character(routes$facility_id)))) {
    skip("FACILITY_DRY_TOPEKA missing in routes cache")
  }

  td <- tempfile("reefer_path_minimal_")
  dir.create(td, recursive = TRUE, showWarnings = FALSE)
  repo_root <- normalizePath(file.path("..", ".."), winslash = "/", mustWork = TRUE)
  oldwd <- getwd()
  on.exit(setwd(oldwd), add = TRUE)
  setwd(repo_root)

  d_dry <- run_mc_once(repo_root, td, "REEFER_MIN_DRY", "diesel", "dry", 9201)
  d_ref <- run_mc_once(repo_root, td, "REEFER_MIN_REFRIG", "diesel", "refrigerated", 9201)
  b_dry <- run_mc_once(repo_root, td, "REEFER_MIN_DRY", "bev", "dry", 9201)
  b_ref <- run_mc_once(repo_root, td, "REEFER_MIN_REFRIG", "bev", "refrigerated", 9201)

  for (res in list(d_dry, d_ref, b_dry, b_ref)) {
    expect_true(is.null(attr(res$out, "status")) || identical(attr(res$out, "status"), 0L))
    expect_true(file.exists(res$summary_out))
    expect_true(file.exists(res$runs_out))
  }

  read_last_track <- function(runs_out) {
    run_id <- utils::read.csv(runs_out, stringsAsFactors = FALSE)$run_id[[1]]
    track_path <- file.path("outputs", "sim_tracks", paste0(run_id, ".csv"))
    expect_true(file.exists(track_path))
    tr <- utils::read.csv(track_path, stringsAsFactors = FALSE)
    tr[nrow(tr), , drop = FALSE]
  }

  ld_dry <- read_last_track(d_dry$runs_out)
  ld_ref <- read_last_track(d_ref$runs_out)
  lb_dry <- read_last_track(b_dry$runs_out)
  lb_ref <- read_last_track(b_ref$runs_out)

  expect_true(abs(suppressWarnings(as.numeric(ld_dry$tru_gal_cum[[1]]))) < 1e-9)
  expect_true(suppressWarnings(as.numeric(ld_ref$tru_gal_cum[[1]])) > 0)
  expect_true(abs(suppressWarnings(as.numeric(lb_dry$tru_kwh_cum[[1]]))) < 1e-9)
  expect_true(suppressWarnings(as.numeric(lb_ref$tru_kwh_cum[[1]])) > 0)

  sum_d_dry <- utils::read.csv(d_dry$summary_out, stringsAsFactors = FALSE)
  sum_d_ref <- utils::read.csv(d_ref$summary_out, stringsAsFactors = FALSE)
  sum_b_dry <- utils::read.csv(b_dry$summary_out, stringsAsFactors = FALSE)
  sum_b_ref <- utils::read.csv(b_ref$summary_out, stringsAsFactors = FALSE)

  expect_true(as.numeric(sum_d_ref$mean[[1]]) > as.numeric(sum_d_dry$mean[[1]]))
  expect_true(as.numeric(sum_b_ref$mean[[1]]) > as.numeric(sum_b_dry$mean[[1]]))
})
