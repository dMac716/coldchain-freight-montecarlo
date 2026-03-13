#!/usr/bin/env Rscript
# scripts/gen_test_fixtures.R
#
# Regenerates tests/fixtures/ deterministically from hardcoded constants.
# Safe to run multiple times — overwrites existing fixture files.
#
# Usage:
#   Rscript scripts/gen_test_fixtures.R
#   make gen-fixtures
#
# Assumptions documented in tests/fixtures/README.md.

suppressPackageStartupMessages(library(optparse))

option_list <- list(
  make_option(c("--out"), type = "character",
              default = "tests/fixtures",
              help = "Root output directory [default: tests/fixtures]")
)
opt <- parse_args(OptionParser(option_list = option_list))

FIXTURE_ROOT <- opt$out
INPUTS_DIR   <- file.path(FIXTURE_ROOT, "inputs")
DERIVED_DIR  <- file.path(FIXTURE_ROOT, "derived")

dir.create(INPUTS_DIR,  recursive = TRUE, showWarnings = FALSE)
dir.create(DERIVED_DIR, recursive = TRUE, showWarnings = FALSE)

write_csv <- function(df, path) {
  utils::write.csv(df, path, row.names = FALSE, quote = TRUE)
  message("  wrote ", path, "  (", nrow(df), " row", if (nrow(df) != 1) "s", ")")
}

cat("gen_test_fixtures.R: writing fixture bundle to", FIXTURE_ROOT, "\n")

# ---------------------------------------------------------------------------
# scenarios.csv — one smoke scenario only
# Matches the SMOKE_LOCAL row in data/inputs_local/scenarios.csv exactly,
# plus the struct needed for read_inputs_local() to resolve scenario params.
# ---------------------------------------------------------------------------
write_csv(
  data.frame(
    scenario_id                 = "SMOKE_LOCAL",
    scenario                    = "SMOKE_LOCAL",
    description                 = "Synthetic fixture scenario — smoke / CI use only",
    fu_id                       = "FU_1000_KCAL",
    FU_kcal                     = 1000,
    spatial_structure           = "SMOKE_LOCAL",
    regionalized_distance_scale = 1,
    distance_distribution_id    = "dist_smoke_local",
    distance_model              = "fixed",
    grid_case                   = "NA",
    grid_co2_g_per_kwh          = "",
    status                      = "SMOKE_READY",
    needed                      = "",
    source_plan                 = "",
    notes                       = "Fixture only. Do not use for REAL_RUN.",
    stringsAsFactors = FALSE
  ),
  file.path(INPUTS_DIR, "scenarios.csv")
)

# ---------------------------------------------------------------------------
# scenario_matrix.csv — one variant: SMOKE_LOCAL, diesel, refrigerated
# ---------------------------------------------------------------------------
write_csv(
  data.frame(
    variant_id       = "SMOKE_LOCAL_DIESEL_REEFER",
    scenario_id      = "SMOKE_LOCAL",
    product_mode     = "REFRIGERATED",
    spatial_structure = "SMOKE_LOCAL",
    powertrain       = "diesel",
    powertrain_config = "DIESEL_TRU_DIESEL",
    trailer_type     = "refrigerated",
    refrigeration_mode = "diesel_tru",
    grid_case        = "NA",
    run_group        = "SMOKE_LOCAL",
    status           = "SMOKE_READY",
    notes            = "Fixture variant — smoke / CI use only",
    stringsAsFactors = FALSE
  ),
  file.path(INPUTS_DIR, "scenario_matrix.csv")
)

# ---------------------------------------------------------------------------
# products.csv — one product: refrigerated freshpet_vital
# Values from PRIMARY_MEASURED source in data/inputs_local/products.csv.
# ---------------------------------------------------------------------------
write_csv(
  data.frame(
    product_id            = "freshpet_vital_large_breed",
    product_mode          = "REFRIGERATED",
    preservation          = "refrigerated",
    kcal_per_kg           = 2375,
    kcal_per_cup          = 337,
    moisture_pct_as_fed   = 56.7,
    packaging_mass_frac   = 0.0118942731277533,
    net_fill_kg           = 2.27,
    primary_package_kg    = 0.027,
    gross_mass_kg         = 2.297,
    source_id             = "freshpet_vital_large_breed_2026",
    source_page           = "p2-p3",
    status                = "PRIMARY_MEASURED",
    notes                 = "Primary refrigerated product. Fixture copy.",
    stringsAsFactors = FALSE
  ),
  file.path(INPUTS_DIR, "products.csv")
)

# ---------------------------------------------------------------------------
# emissions_factors.csv — diesel refrigerated + diesel dry-van for completeness
# Values from data/inputs_local/emissions_factors.csv.
# ---------------------------------------------------------------------------
write_csv(
  data.frame(
    factor_id          = c("diesel_refrigerated_diesel_tru", "diesel_dryvan_none"),
    powertrain         = c("diesel",                          "diesel"),
    trailer_type       = c("refrigerated",                    "dry_van"),
    refrigeration_mode = c("diesel_tru",                      "none"),
    co2_g_per_ton_mile = c(109,                               105),
    co2_g_per_mile     = c(2066,                              1784),
    default_payload_tons = c(17.60,                           16.35),
    kwh_per_mile_tract = c("",   ""),
    kwh_per_mile_tru   = c("",   ""),
    grid_co2_g_per_kwh = c("",   ""),
    source_id          = c("smartway_olt_2025", "smartway_olt_2025"),
    source_page        = c("p13 Table 3; p14 Table 4", "p13 Table 3; p14 Table 4"),
    status             = c("OK", "OK"),
    notes              = c("Diesel refrigerated baseline — fixture copy.",
                           "Diesel dry-van baseline — fixture copy."),
    stringsAsFactors = FALSE
  ),
  file.path(INPUTS_DIR, "emissions_factors.csv")
)

# ---------------------------------------------------------------------------
# sampling_priors.csv — all entries use distribution=fixed to eliminate
# randomness entirely.  Values are the mode/midpoint of each production prior.
#
# Applies_to scope rules:
#   *               → every variant
#   SMOKE_LOCAL_*   → smoke variants only
#   DIESEL          → diesel powertrain
#   DIESEL_TRU      → diesel TRU refrigeration
# ---------------------------------------------------------------------------
write_csv(
  data.frame(
    param_id     = c(
      "FU_kcal",
      "kcal_per_kg_dry",
      "kcal_per_kg_reefer",
      "pkg_kg_per_kg_dry",
      "pkg_kg_per_kg_reefer",
      "distance_miles",
      "default_payload_tons",
      "linehaul_avg_speed_mph",
      "truck_g_per_ton_mile",
      "diesel_tru_gal_per_hour",
      "diesel_tru_startup_gal",
      "diesel_co2_g_per_gallon",
      "reefer_extra_g_per_ton_mile",
      "util_dry",
      "util_reefer"
    ),
    distribution = rep("fixed", 15),
    p1 = c(
      1000,                   # FU_kcal
      3675,                   # kcal_per_kg_dry
      2375,                   # kcal_per_kg_reefer
      0.0121,                 # pkg_kg_per_kg_dry
      0.0118942731277533,     # pkg_kg_per_kg_reefer
      1200,                   # distance_miles (SMOKE_LOCAL fixed dist)
      16.35,                  # default_payload_tons
      55,                     # linehaul_avg_speed_mph (midpoint of triangular)
      105,                    # truck_g_per_ton_mile
      0.6,                    # diesel_tru_gal_per_hour (mode of triangular)
      0.05,                   # diesel_tru_startup_gal (mode of triangular)
      10180,                  # diesel_co2_g_per_gallon
      0,                      # reefer_extra_g_per_ton_mile
      0.95,                   # util_dry (mode of triangular)
      0.9                     # util_reefer (mode of triangular)
    ),
    p2 = rep("", 15),
    p3 = rep("", 15),
    units = c(
      "kcal_per_fu", "kcal_per_kg", "kcal_per_kg",
      "kg_pkg_per_kg_product", "kg_pkg_per_kg_product",
      "miles", "tons", "mph",
      "gco2_per_ton_mile", "gal_per_hour", "gal_per_trip",
      "gco2_per_gallon", "gco2_per_ton_mile",
      "unitless", "unitless"
    ),
    applies_to = c(
      "*", "*", "*",
      "*", "*",
      "SMOKE_LOCAL_*", "*", "*",
      "DIESEL", "DIESEL_TRU", "DIESEL_TRU",
      "DIESEL_TRU", "*",
      "*", "*"
    ),
    source_id = c(
      "fixture", "fixture", "fixture",
      "fixture", "fixture",
      "fixture", "fixture", "fixture",
      "fixture", "fixture", "fixture",
      "fixture", "fixture",
      "fixture", "fixture"
    ),
    source_page = rep("", 15),
    status      = rep("OK", 15),
    notes       = c(
      "Functional unit locked at 1000 kcal. (fixture)",
      "Dry energy density midpoint. (fixture)",
      "Reefer energy density midpoint. (fixture)",
      "Dry packaging fraction. (fixture)",
      "Reefer packaging fraction. (fixture)",
      "Fixed 1200-mile smoke distance. (fixture)",
      "Default payload midpoint. (fixture)",
      "Line-haul speed midpoint. (fixture)",
      "Diesel traction factor. (fixture)",
      "Diesel TRU burn rate midpoint. (fixture)",
      "Diesel TRU startup fuel midpoint. (fixture)",
      "Diesel CO2 factor. (fixture)",
      "No reefer increment for diesel in this fixture. (fixture)",
      "Payload utilisation dry midpoint. (fixture)",
      "Payload utilisation reefer midpoint. (fixture)"
    ),
    stringsAsFactors = FALSE
  ),
  file.path(INPUTS_DIR, "sampling_priors.csv")
)

# ---------------------------------------------------------------------------
# histogram_config.csv — two metrics wide enough to catch any fixture output
# ---------------------------------------------------------------------------
write_csv(
  data.frame(
    metric    = c("gco2_reefer",  "gco2_dry",   "ghg_total",
                  "ghg_traction", "ghg_refrigeration", "diff_gco2", "ratio"),
    min       = c(-500,           -500,          -500,
                  -500,           -500,           -5000,   0),
    max       = c(2000,           2000,           2000,
                  2000,            2000,           2000,   10),
    bins      = c(50,              50,             50,
                  50,              50,              50,    50),
    status    = rep("FIXTURE", 7),
    notes     = rep("Wide bounds — fixture only. Not calibrated.", 7),
    calibration_run_group = rep("SMOKE_LOCAL", 7),
    calibrated_at_utc     = rep("", 7),
    calibration_method    = rep("fixture_wide_bounds", 7),
    stringsAsFactors = FALSE
  ),
  file.path(INPUTS_DIR, "histogram_config.csv")
)

# ---------------------------------------------------------------------------
# grid_ci.csv — US average only
# ---------------------------------------------------------------------------
write_csv(
  data.frame(
    grid_case       = "US_AVG",
    co2_g_per_kwh   = 373.4,
    source_id       = "egrid_2022_summary_tables_xlsx",
    source_page     = "Table 3 row U.S.",
    notes           = "US average grid intensity. Fixture copy.",
    status          = "OK",
    stringsAsFactors = FALSE
  ),
  file.path(INPUTS_DIR, "grid_ci.csv")
)

# ---------------------------------------------------------------------------
# assumptions_used.csv — minimal required rows
# ---------------------------------------------------------------------------
write_csv(
  data.frame(
    assumption       = c("System boundary", "Functional unit"),
    value            = c("Manufacturing to Retail Transportation",
                         "1000 kcal delivered to retail"),
    notes            = c("Do not modify boundary", "Do not modify functional unit"),
    placeholder_note = c("FIXTURE", "FIXTURE"),
    stringsAsFactors = FALSE
  ),
  file.path(INPUTS_DIR, "assumptions_used.csv")
)

# ---------------------------------------------------------------------------
# functional_unit.csv
# ---------------------------------------------------------------------------
write_csv(
  data.frame(
    fu_id     = "FU_1000_KCAL",
    fu_kcal   = 1000,
    status    = "OK",
    source_id = "fixture",
    source_page = "",
    notes     = "Functional unit fixture.",
    stringsAsFactors = FALSE
  ),
  file.path(INPUTS_DIR, "functional_unit.csv")
)

# ---------------------------------------------------------------------------
# factors.csv — Refrigerated row only (matches the diesel_reefer variant)
# ---------------------------------------------------------------------------
write_csv(
  data.frame(
    mode_category       = "Refrigerated",
    co2_g_per_ton_mile  = 109,
    co2_g_per_mile      = 2066,
    default_payload_tons = 17.60,
    source_id           = "SMARTWAY_OLT_2025",
    source_page         = "p13 Table 3; p14 Table 4",
    notes               = "Fixture copy.",
    stringsAsFactors = FALSE
  ),
  file.path(INPUTS_DIR, "factors.csv")
)

# ---------------------------------------------------------------------------
# derived/faf_distance_distributions.csv — smoke entry only
# ---------------------------------------------------------------------------
write_csv(
  data.frame(
    distance_distribution_id = "dist_smoke_local",
    scenario_id              = "SMOKE_LOCAL",
    source_zip               = "synthetic",
    commodity_filter         = "n/a",
    mode_filter              = "n/a",
    distance_model           = "fixed",
    p05_miles                = 1200,
    p50_miles                = 1200,
    p95_miles                = 1200,
    mean_miles               = 1200,
    min_miles                = 1200,
    max_miles                = 1200,
    n_records                = 1,
    status                   = "SMOKE_READY",
    source_id                = "fixture",
    notes                    = "Synthetic smoke distribution — fixture only.",
    stringsAsFactors = FALSE
  ),
  file.path(DERIVED_DIR, "faf_distance_distributions.csv")
)

cat("gen_test_fixtures.R: done.\n")
cat("  Fixture root:  ", normalizePath(FIXTURE_ROOT), "\n")
cat("  Inputs dir:    ", normalizePath(INPUTS_DIR),   "\n")
cat("  Derived dir:   ", normalizePath(DERIVED_DIR),  "\n")
cat("  Regenerate:    Rscript scripts/gen_test_fixtures.R\n")
cat("  Or:            make gen-fixtures\n")
