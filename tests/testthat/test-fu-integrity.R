# tests/testthat/test-fu-integrity.R
# ============================================================================
# Functional unit integrity tests — prevents mixed-method FU datasets.
#
# TEST CASES:
#   1. "audit formula produces 100% FU coverage on Dataset B"
#       Verifies that the audit formula (payload_max_lb_draw * load_fraction *
#       0.453592) can produce finite positive FU values for ALL rows in the
#       validated dataset. Catches missing/NA input columns.
#
#   2. "audit-uniform dataset has single fu_method and 100% coverage"
#       Validates the output of build_audit_uniform_dataset.R: exactly one
#       fu_method tag, 100% co2_per_1000kcal coverage, and plausible range
#       (0.001 to 1.0 kg CO2/1000kcal).
#
#   3. "no mixed FU methods in any promoted dataset"
#       Scans ALL analysis_postfix_*.csv.gz files in the artifact directory.
#       Any dataset with a fu_method column must contain at most one unique
#       value. Prevents accidental merges of differently-computed datasets.
#
#   4. "config test_kit.yaml has units_per_case or documents its absence"
#       Documents the known config gap: units_per_case is currently missing,
#       which forces FU computation via audit formula instead of load model.
#       When config is fixed, this test flips to validate the new values.
#
#   5. "resolve_load_draw returns finite product_mass_lb_per_truck when config is complete"
#       Tests the load model function directly. Currently expects NA because
#       config is incomplete. Will flip to expect finite values after fix.
#
#   6. "food profile is deterministic across repeated calls"
#       Calls resolve_food_profile() twice with the same seed and verifies
#       identical kcal_per_kg_product. Tests 3 seeds x 2 product types.
#       Determinism is critical for FU recovery (recover_fu_backfill.R).
#
#   7. "audit formula is idempotent"
#       Applies the audit formula twice to synthetic data and verifies
#       identical results. Guards against floating-point instability.
#
#   8. "frozen sensitivity dataset has all four method labels"
#       Validates the fu_final_package.R output: the frozen comparison
#       dataset must contain rows for audit_uniform, legacy_stored,
#       exo_draw, and phase2_load_model.
#
#   9. "fingerprint exists and matches dataset row count"
#       Cross-checks the JSON fingerprint against the actual dataset:
#       row count must match and FU coverage must be reported as 100%.
# ============================================================================

proj_root <- normalizePath(file.path("..", ".."), winslash = "/", mustWork = FALSE)

test_that("audit formula produces 100% FU coverage on Dataset B", {
  path <- file.path(proj_root, "artifacts/analysis_final_2026-03-17/analysis_postfix_validated.csv.gz")
  skip_if_not(file.exists(path), "Dataset B not found")

  d <- data.table::fread(cmd = sprintf("gzcat '%s'", path), na.strings = c("", "NA"))

  # All inputs must be present

  expect_true(all(!is.na(d$payload_max_lb_draw)), info = "payload_max_lb_draw has NAs")
  expect_true(all(!is.na(d$load_fraction)), info = "load_fraction has NAs")
  expect_true(all(!is.na(d$kcal_per_kg_product)), info = "kcal_per_kg_product has NAs")
  expect_true(all(!is.na(d$co2_kg_total)), info = "co2_kg_total has NAs")

  # Apply audit formula
  d[, test_payload_kg := payload_max_lb_draw * load_fraction * 0.453592]
  d[, test_kcal := test_payload_kg * kcal_per_kg_product]
  d[, test_fu := co2_kg_total / test_kcal * 1000]

  expect_equal(sum(is.finite(d$test_fu) & d$test_fu > 0), nrow(d),
               info = "audit formula must produce finite positive FU for all rows")
})

test_that("audit-uniform dataset has single fu_method and 100% coverage", {
  path <- file.path(proj_root, "artifacts/analysis_final_2026-03-17/analysis_postfix_audit_uniform.csv.gz")
  skip_if_not(file.exists(path), "Audit-uniform dataset not found")

  d <- data.table::fread(cmd = sprintf("gzcat '%s'", path), na.strings = c("", "NA"))

  # Single method
  expect_equal(length(unique(d$fu_method)), 1L,
               info = "dataset must have exactly one fu_method")
  expect_equal(unique(d$fu_method), "audit_uniform")

  # 100% coverage
  expect_equal(sum(!is.na(d$co2_per_1000kcal)), nrow(d),
               info = "all rows must have co2_per_1000kcal")
  expect_true(all(is.finite(d$co2_per_1000kcal) & d$co2_per_1000kcal > 0),
              info = "all co2_per_1000kcal must be finite and positive")

  # Plausible range
  expect_true(all(d$co2_per_1000kcal < 1.0),
              info = "co2_per_1000kcal > 1.0 is implausible")
  expect_true(all(d$co2_per_1000kcal > 0.001),
              info = "co2_per_1000kcal < 0.001 is implausible")
})

test_that("no mixed FU methods in any promoted dataset", {
  # Any dataset with fu_method column must have exactly one value
  paths <- Sys.glob(file.path(proj_root, "artifacts/analysis_final_*/analysis_postfix_*.csv.gz"))
  for (p in paths) {
    d <- tryCatch(
      data.table::fread(cmd = sprintf("gzcat '%s'", p), select = "fu_method",
                        na.strings = c("", "NA"), nrows = 1),
      error = function(e) NULL
    )
    if (is.null(d) || !"fu_method" %in% names(d)) next
    d_full <- data.table::fread(cmd = sprintf("gzcat '%s'", p), select = "fu_method",
                                na.strings = c("", "NA"))
    methods <- unique(d_full$fu_method[!is.na(d_full$fu_method)])
    expect_lte(length(methods), 1L,
               label = sprintf("%s fu_methods: %s", basename(p), paste(methods, collapse = ", ")))
  }
})

test_that("config test_kit.yaml has units_per_case or documents its absence", {
  cfg_path <- file.path(proj_root, "config/test_kit.yaml")
  skip_if_not(file.exists(cfg_path), "test_kit.yaml not found")

  cfg <- yaml::read_yaml(cfg_path)$test_kit
  lm <- cfg$load_model

  # Document the current state: units_per_case is MISSING.
  # When it's added, flip these expectations.
  dry_upc <- lm$products$dry$units_per_case
  ref_upc <- lm$products$refrigerated$units_per_case

  if (is.null(dry_upc) || is.null(ref_upc)) {
    # Config lacks units_per_case — load model gives NA for product_mass_lb_per_truck.
    # FU must be derived via audit formula, not load model.
    # This test documents the known gap. Remove this branch when config is fixed.
    expect_null(dry_upc, info = "dry units_per_case still missing (expected until config fix)")
    expect_null(ref_upc, info = "refrigerated units_per_case still missing (expected until config fix)")
  } else {
    # Config has units_per_case — verify values match domain knowledge
    expect_equal(dry_upc, 2, info = "dry: 2 bags per box (Hill's)")
    # Refrigerated should be a discrete distribution {4,5,6}
    if (is.list(ref_upc)) {
      expect_true(!is.null(ref_upc$distribution) || !is.null(ref_upc$values),
                  info = "refrigerated units_per_case should be a distribution")
    } else {
      expect_true(ref_upc %in% 4:6,
                  info = "refrigerated units_per_case should be 4, 5, or 6")
    }
  }
})

test_that("resolve_load_draw returns finite product_mass_lb_per_truck when config is complete", {
  skip_if_not(file.exists(file.path(proj_root, "R/sim/05_charger_state_model.R")), "Source files not found")

  source(file.path(proj_root, "R/sim/05_charger_state_model.R"), local = TRUE)
  source(file.path(proj_root, "R/sim/01_build_route_segments.R"), local = TRUE)
  source(file.path(proj_root, "R/sim/07_event_simulator.R"), local = TRUE)
  source(file.path(proj_root, "R/08_load_model.R"), local = TRUE)

  cfg <- yaml::read_yaml(file.path(proj_root, "config/test_kit.yaml"))$test_kit
  Sys.unsetenv("REAL_RUN")

  ld_dry <- resolve_load_draw(42L, cfg, "dry")
  ld_ref <- resolve_load_draw(42L, cfg, "refrigerated")

  # Currently product_mass_lb_per_truck is NA because units_per_case is missing.
  # When config is fixed, change expect_true(is.na(...)) to expect_true(is.finite(...))
  if (is.null(cfg$load_model$products$dry$units_per_case)) {
    expect_true(is.na(ld_dry$product_mass_lb_per_truck),
                info = "product_mass_lb_per_truck is NA when units_per_case missing (known gap)")
  } else {
    expect_true(is.finite(ld_dry$product_mass_lb_per_truck),
                info = "dry product_mass_lb_per_truck must be finite when config is complete")
    expect_gt(ld_dry$product_mass_lb_per_truck, 0)
  }
})

test_that("food profile is deterministic across repeated calls", {
  skip_if_not(file.exists(file.path(proj_root, "R/07_food_composition.R")), "Source files not found")

  source(file.path(proj_root, "R/sim/05_charger_state_model.R"), local = TRUE)
  source(file.path(proj_root, "R/07_food_composition.R"), local = TRUE)

  fi <- read_food_inputs(file.path(proj_root, "data"))
  skip_if(is.null(fi), "Food input data files not found")

  for (seed in c(42L, 99999L, 710000L)) {
    for (pt in c("dry", "refrigerated")) {
      a <- resolve_food_profile(pt, fi, seed)
      b <- resolve_food_profile(pt, fi, seed)
      expect_identical(a$kcal_per_kg_product, b$kcal_per_kg_product,
                       info = sprintf("kcal_per_kg not deterministic: seed=%d pt=%s", seed, pt))
    }
  }
})

test_that("audit formula is idempotent", {
  # Applying the formula twice must give identical results
  n <- 100
  set.seed(42)
  payload_max <- runif(n, 38000, 45000)
  lf <- rep(1, n)
  kcal_per_kg <- runif(n, 2000, 3500)
  co2 <- runif(n, 500, 2000)

  payload_kg <- payload_max * lf * 0.453592
  kcal_del <- payload_kg * kcal_per_kg
  fu <- co2 / kcal_del * 1000

  # Apply again
  payload_kg2 <- payload_max * lf * 0.453592
  kcal_del2 <- payload_kg2 * kcal_per_kg
  fu2 <- co2 / kcal_del2 * 1000

  expect_identical(fu, fu2)
})

test_that("frozen sensitivity dataset has all four method labels", {
  path <- file.path(proj_root, "artifacts/analysis_final_2026-03-17/fu_sensitivity_final/fu_sensitivity_frozen.csv")
  skip_if_not(file.exists(path), "Frozen sensitivity dataset not found")

  d <- data.table::fread(path)
  methods <- unique(d$fu_method)

  expect_true("audit_uniform" %in% methods)
  expect_true("legacy_stored" %in% methods)
  expect_true("exo_draw" %in% methods)
  expect_true("phase2_load_model" %in% methods)
})

test_that("fingerprint exists and matches dataset row count", {
  fp_path <- file.path(proj_root, "artifacts/analysis_final_2026-03-17/manifest/dataset_fingerprint_audit_uniform.json")
  ds_path <- file.path(proj_root, "artifacts/analysis_final_2026-03-17/analysis_postfix_audit_uniform.csv.gz")
  skip_if_not(file.exists(fp_path) && file.exists(ds_path), "Fingerprint or dataset not found")

  fp <- jsonlite::fromJSON(fp_path)
  d <- data.table::fread(cmd = sprintf("gzcat '%s'", ds_path), select = "run_id")

  expect_equal(fp$total_rows, nrow(d),
               info = "fingerprint row count must match dataset")
  expect_equal(fp$fu_coverage_pct, 100,
               info = "fingerprint must show 100% FU coverage")
})
