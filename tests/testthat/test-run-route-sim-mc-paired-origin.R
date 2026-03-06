test_that("run_route_sim_mc materializes paired-origin bundles with two labeled runs", {
  routes_path <- file.path("..", "..", "data", "derived", "routes_facility_to_petco.csv")
  if (!file.exists(routes_path)) skip("routes cache missing for paired-origin integration test")
  routes <- utils::read.csv(routes_path, stringsAsFactors = FALSE)
  need_fac <- c("FACILITY_DRY_TOPEKA", "FACILITY_REFRIG_ENNIS")
  if (!all(need_fac %in% unique(as.character(routes$facility_id)))) {
    skip("required dry/refrigerated facilities not present in routes cache")
  }

  td <- tempfile("paired_origin_mc_")
  dir.create(td, recursive = TRUE)
  bundle_root <- file.path(td, "run_bundle")
  summary_out <- file.path(td, "summary.csv")
  runs_out <- file.path(td, "runs.csv")
  repo_root <- normalizePath(file.path("..", ".."), winslash = "/", mustWork = TRUE)

  cmd <- c(
    file.path(repo_root, "tools", "run_route_sim_mc.R"),
    "--config", file.path(repo_root, "test_kit.yaml"),
    "--scenario", "paired_origin_regression",
    "--powertrain", "diesel",
    "--product_type", "dry",
    "--traffic_mode", "freeflow",
    "--paired_origin_networks", "true",
    "--facility_id_dry", "FACILITY_DRY_TOPEKA",
    "--facility_id_refrigerated", "FACILITY_REFRIG_ENNIS",
    "--n", "3",
    "--seed", "2500",
    "--bundle_root", bundle_root,
    "--summary_out", summary_out,
    "--runs_out", runs_out
  )
  oldwd <- getwd()
  on.exit(setwd(oldwd), add = TRUE)
  setwd(repo_root)
  status <- system2("Rscript", cmd, stdout = TRUE, stderr = TRUE)
  expect_true(is.null(attr(status, "status")) || identical(attr(status, "status"), 0L))

  runs <- utils::read.csv(runs_out, stringsAsFactors = FALSE)
  expect_true(all(!is.na(runs$origin_network) & nzchar(as.character(runs$origin_network))))

  by_pair <- split(runs, runs$pair_id)
  expect_equal(length(by_pair), 3)
  for (p in by_pair) {
    nets <- sort(unique(as.character(p$origin_network)))
    expect_equal(nets, c("dry_factory_set", "refrigerated_factory_set"))
    expect_true(length(unique(as.character(p$pair_id))) == 1)

    # CRN exogenous draws should match across origin pair members.
    expect_equal(length(unique(p$payload_max_lb_draw)), 1)
    expect_equal(length(unique(p$load_unload_min)), 1)
    expect_equal(length(unique(p$refuel_stop_min)), 1)
    expect_equal(length(unique(p$connector_overhead_min)), 1)
  }

  pair_dirs <- list.dirs(bundle_root, full.names = TRUE, recursive = FALSE)
  pair_dirs <- pair_dirs[grepl("/pair_", pair_dirs)]
  expect_equal(length(pair_dirs), 3)
  for (pd in pair_dirs) {
    s <- utils::read.csv(file.path(pd, "summaries.csv"), stringsAsFactors = FALSE)
    r <- utils::read.csv(file.path(pd, "runs.csv"), stringsAsFactors = FALSE)
    expect_equal(nrow(s), 2)
    expect_equal(nrow(r), 2)
    expect_true(all(!is.na(r$origin_network) & nzchar(as.character(r$origin_network))))
    expect_equal(sort(unique(as.character(r$origin_network))), c("dry_factory_set", "refrigerated_factory_set"))
  }
})
