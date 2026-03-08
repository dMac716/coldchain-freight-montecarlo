test_that("every ledger dataset_key appears in provenance manifest", {
  td <- tempfile("lci_prov_")
  dir.create(td, recursive = TRUE)
  bundle_root <- file.path(td, "run_bundle")
  outdir <- file.path(td, "lci_reports")
  bd <- file.path(bundle_root, "run1")
  dir.create(bd, recursive = TRUE)

  sm <- data.frame(
    run_id = "run1",
    scenario = "SCEN_LCI",
    product_type = "dry",
    units_per_truck = 100,
    units_per_case_draw = 2,
    kcal_per_truck = 10000,
    kcal_delivered = 10000,
    diesel_gal_propulsion = 10,
    diesel_gal_tru = 0,
    energy_kwh_propulsion = 0,
    energy_kwh_tru = 0,
    delivery_time_min = 100,
    driver_driving_min = 60,
    driver_on_duty_min = 90,
    driver_off_duty_min = 10,
    stringsAsFactors = FALSE
  )
  utils::write.csv(sm, file.path(bd, "summaries.csv"), row.names = FALSE)

  up <- data.frame(
    run_id = "run1",
    product_type = "dry",
    ingredient_raw = "chicken",
    lci_key = "chicken",
    mass_fraction = 1,
    kg_ingredient_per_1000kcal = 0.2,
    upstream_kgco2_per_1000kcal = 0.7,
    confidence = "high",
    stringsAsFactors = FALSE
  )
  utils::write.csv(up, file.path(bd, "upstream_ingredients.csv"), row.names = FALSE)

  jsonlite::write_json(list(
    run_id = "run1",
    product_type = "dry",
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

  cmd <- c(
    file.path("..", "..", "tools", "make_lci_inventory_reports.R"),
    "--bundle_dir", bundle_root,
    "--product_type", "dry",
    "--outdir", outdir
  )
  status <- system2("Rscript", cmd, stdout = TRUE, stderr = TRUE)
  expect_true(is.null(attr(status, "status")) || identical(attr(status, "status"), 0L))

  ledger <- utils::read.csv(file.path(outdir, "inventory_ledger.csv"), stringsAsFactors = FALSE)
  prov <- utils::read.csv(file.path(outdir, "provenance_manifest.csv"), stringsAsFactors = FALSE)

  ledger_keys <- unique(as.character(ledger$dataset_key))
  ledger_keys <- ledger_keys[nzchar(ledger_keys)]
  missing <- setdiff(ledger_keys, unique(as.character(prov$dataset_key)))
  expect_length(missing, 0)
})
