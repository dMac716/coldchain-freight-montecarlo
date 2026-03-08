test_that("make_lci_inventory_reports builds ledger and normalizes distribution flows", {
  td <- tempfile("lci_ledger_")
  dir.create(td, recursive = TRUE)
  bundle_root <- file.path(td, "run_bundle")
  outdir <- file.path(td, "lci_reports")
  dir.create(bundle_root, recursive = TRUE)

  make_bundle <- function(run_id, pair_id, diesel_gal, kcal_truck) {
    bd <- file.path(bundle_root, run_id)
    dir.create(bd, recursive = TRUE)
    sm <- data.frame(
      run_id = run_id,
      pair_id = pair_id,
      scenario = "SCEN_LCI",
      product_type = "dry",
      units_per_truck = 100,
      units_per_case_draw = 2,
      kcal_per_truck = kcal_truck,
      kcal_delivered = kcal_truck,
      diesel_gal_propulsion = diesel_gal,
      diesel_gal_tru = 0,
      energy_kwh_propulsion = 0,
      energy_kwh_tru = 0,
      delivery_time_min = 120,
      driver_driving_min = 80,
      driver_on_duty_min = 110,
      driver_off_duty_min = 10,
      stringsAsFactors = FALSE
    )
    utils::write.csv(sm, file.path(bd, "summaries.csv"), row.names = FALSE)

    up <- data.frame(
      run_id = run_id,
      product_type = "dry",
      ingredient_raw = c("chicken", "rice"),
      lci_key = c("chicken", "rice"),
      mass_fraction = c(0.6, 0.4),
      kg_ingredient_per_1000kcal = c(0.12, 0.08),
      upstream_kgco2_per_1000kcal = c(0.5, 0.2),
      confidence = c("high", "med"),
      stringsAsFactors = FALSE
    )
    utils::write.csv(up, file.path(bd, "upstream_ingredients.csv"), row.names = FALSE)

    jsonlite::write_json(list(
      run_id = run_id,
      scenario = "SCEN_LCI",
      product_type = "dry",
      seed = 123,
      config = list(
        load_model = list(
          trailer = list(pallets_max = 26),
          packaging = list(
            pallet_tare_lb = list(distribution = list(mode = 40)),
            case_tare_lb = list(dry = list(distribution = list(mode = 1.0)))
          )
        ),
        lci = list(
          source_version = "2026-03-05",
          lci_workbook_path = file.path(td, "missing_lci.xlsx"),
          manufacturing = list(electricity_kwh_per_1000kcal = 0.03, natural_gas_mj_per_1000kcal = 0.12)
        )
      )
    ), file.path(bd, "params.json"), auto_unbox = TRUE, pretty = TRUE)
  }

  make_bundle("run1", "pairA", diesel_gal = 10, kcal_truck = 10000)
  make_bundle("run2", "pairA", diesel_gal = 20, kcal_truck = 20000)

  cmd <- c(
    file.path("..", "..", "tools", "make_lci_inventory_reports.R"),
    "--bundle_dir", bundle_root,
    "--product_type", "dry",
    "--functional_unit", "1000kcal",
    "--outdir", outdir
  )
  status <- system2("Rscript", cmd, stdout = TRUE, stderr = TRUE)
  expect_true(is.null(attr(status, "status")) || identical(attr(status, "status"), 0L))

  ledger_path <- file.path(outdir, "inventory_ledger.csv")
  summary_path <- file.path(outdir, "inventory_summary_by_stage.csv")
  expect_true(file.exists(ledger_path))
  expect_true(file.exists(summary_path))

  ledger <- utils::read.csv(ledger_path, stringsAsFactors = FALSE)
  req <- c("system_id", "stage", "process", "flow_name", "direction", "amount", "unit", "functional_unit_basis", "dataset_key", "source_file", "source_version", "assumption_notes", "confidence")
  expect_true(all(req %in% names(ledger)))

  stage_sum <- utils::read.csv(summary_path, stringsAsFactors = FALSE)
  expect_true(any(is.finite(stage_sum$p50)))

  dist <- ledger[ledger$stage == "distribution" & ledger$flow_name == "tractor_diesel", , drop = FALSE]
  expect_equal(nrow(dist), 2)
  expect_equal(dist$amount[[1]], dist$amount[[2]], tolerance = 1e-10)
})
