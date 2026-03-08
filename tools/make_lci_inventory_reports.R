#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
})

script_file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
script_path <- if (length(script_file_arg) > 0) sub("^--file=", "", script_file_arg[[1]]) else "tools/make_lci_inventory_reports.R"
script_dir <- dirname(normalizePath(script_path, winslash = "/", mustWork = TRUE))
repo_root <- normalizePath(file.path(script_dir, ".."), winslash = "/", mustWork = TRUE)

source(file.path(repo_root, "R", "07_food_composition.R"), local = FALSE)
source(file.path(repo_root, "R", "11_lci_reports.R"), local = FALSE)

option_list <- list(
  make_option(c("--bundle_dir"), type = "character", default = "outputs/run_bundle"),
  make_option(c("--product_type"), type = "character", default = "refrigerated"),
  make_option(c("--functional_unit"), type = "character", default = "1000kcal"),
  make_option(c("--outdir"), type = "character", default = "outputs/lci_reports"),
  make_option(c("--coverage_threshold"), type = "double", default = 0.25)
)
opt <- parse_args(OptionParser(option_list = option_list))

product_type <- tolower(as.character(opt$product_type %||% "refrigerated"))
if (!product_type %in% c("dry", "refrigerated")) {
  stop("--product_type must be one of: dry, refrigerated")
}
fu_basis <- paste0("per_", gsub("[^A-Za-z0-9]+", "", as.character(opt$functional_unit %||% "1000kcal")))
if (!identical(fu_basis, "per_1000kcal")) {
  warning("Only 1000kcal functional unit is currently supported; proceeding with per_1000kcal normalization.")
  fu_basis <- "per_1000kcal"
}

bundle_dirs <- lci_resolve_bundle_dirs(opt$bundle_dir)
if (length(bundle_dirs) == 0) stop("No run bundles found at ", opt$bundle_dir)

outdir <- opt$outdir
raw_costs_dir <- file.path(outdir, "raw_flow_costs")
cards_dir <- file.path(outdir, "process_cards")
dir.create(outdir, recursive = TRUE, showWarnings = FALSE)
dir.create(raw_costs_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(cards_dir, recursive = TRUE, showWarnings = FALSE)

schema_path <- file.path(repo_root, "data", "inputs", "lci_inventory_schema.csv")
if (!file.exists(schema_path)) {
  dir.create(dirname(schema_path), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(lci_inventory_schema_rows(), schema_path, row.names = FALSE)
}

read_summary <- function(bundle_dir) {
  p <- file.path(bundle_dir, "summaries.csv")
  if (!file.exists(p) || !isTRUE(file.info(p)$size > 0)) return(data.frame())
  utils::read.csv(p, stringsAsFactors = FALSE)
}

read_upstream <- function(bundle_dir) {
  p <- file.path(bundle_dir, "upstream_ingredients.csv")
  if (!file.exists(p) || !isTRUE(file.info(p)$size > 0)) return(data.frame())
  utils::read.csv(p, stringsAsFactors = FALSE)
}

read_params <- function(bundle_dir) {
  p <- file.path(bundle_dir, "params.json")
  if (!file.exists(p)) return(list())
  tryCatch(jsonlite::fromJSON(p, simplifyVector = TRUE), error = function(e) list())
}

to_num <- function(x) suppressWarnings(as.numeric(x))

make_row <- function(run_id, system_id, stage, process, flow_name, direction, amount, unit, dataset_key, source_file, source_version, assumption_notes, confidence) {
  scalar_chr <- function(x, default = NA_character_) {
    if (is.null(x) || length(x) == 0) return(as.character(default))
    as.character(x[[1]])
  }
  scalar_num <- function(x, default = NA_real_) {
    if (is.null(x) || length(x) == 0) return(as.numeric(default))
    suppressWarnings(as.numeric(x[[1]]))
  }
  data.frame(
    run_id = scalar_chr(run_id),
    system_id = scalar_chr(system_id),
    stage = scalar_chr(stage),
    process = scalar_chr(process),
    flow_name = scalar_chr(flow_name),
    direction = scalar_chr(direction),
    amount = scalar_num(amount),
    unit = scalar_chr(unit),
    functional_unit_basis = fu_basis,
    dataset_key = scalar_chr(dataset_key),
    source_file = scalar_chr(source_file),
    source_version = scalar_chr(source_version, default = ""),
    assumption_notes = scalar_chr(assumption_notes, default = ""),
    confidence = scalar_chr(confidence, default = "low"),
    stringsAsFactors = FALSE
  )
}

ledger_rows <- list()
li <- 0L
all_dataset_refs <- list()
dr_i <- 0L

for (bd in bundle_dirs) {
  sm <- read_summary(bd)
  if (nrow(sm) == 0) next
  up <- read_upstream(bd)
  pm <- read_params(bd)
  cfg <- pm$config %||% list()
  run_id <- as.character(sm$run_id[[1]] %||% pm$run_id %||% basename(bd))
  sys_id <- as.character(sm$product_type[[1]] %||% pm$product_type %||% product_type)
  if (nzchar(product_type) && !identical(sys_id, product_type)) next

  kcal_truck <- to_num(sm$kcal_per_truck[[1]] %||% sm$kcal_delivered[[1]] %||% NA_real_)
  if (!is.finite(kcal_truck) || kcal_truck <= 0) {
    warning("Missing kcal_per_truck for run_id=", run_id, "; distribution/packaging normalization may be incomplete")
  }
  per_fu <- if (is.finite(kcal_truck) && kcal_truck > 0) 1000 / kcal_truck else NA_real_

  lci_cfg <- cfg$lci %||% list()
  wb <- as.character(lci_cfg$lci_workbook_path %||% "LCI.xlsx")
  source_version <- as.character(lci_cfg$source_version %||% format(Sys.Date(), "%Y-%m-%d"))

  # Ingredients stage from upstream_ingredients.csv when available.
  if (nrow(up) > 0) {
    for (k in seq_len(nrow(up))) {
      ing <- as.character(up$ingredient_raw[[k]] %||% "ingredient")
      lkey <- as.character(up$lci_key[[k]] %||% "unknown_lci_key")
      kg_ing <- to_num(up$kg_ingredient_per_1000kcal[[k]])
      kgco2 <- to_num(up$upstream_kgco2_per_1000kcal[[k]])
      conf <- tolower(as.character(up$confidence[[k]] %||% "med"))
      li <- li + 1L
      ledger_rows[[li]] <- make_row(run_id, sys_id, "ingredients", ing, paste0("mass_", ing), "input", kg_ing, "kg", lkey, "Product_Information.pdf", source_version, "ingredient-share model", conf)
      li <- li + 1L
      ledger_rows[[li]] <- make_row(run_id, sys_id, "ingredients", ing, paste0("ghg_", ing), "output", kgco2, "kgco2e", lkey, wb, source_version, "mapped upstream CO2e", conf)
    }
  } else {
    if (lci_is_real_run_env()) stop("REAL_RUN requires ingredient inventory rows; upstream_ingredients.csv missing for run_id=", run_id)
    li <- li + 1L
    ledger_rows[[li]] <- make_row(run_id, sys_id, "ingredients", "ingredients_total", "ingredients_mass", "input", NA_real_, "kg", "NEEDS_SOURCE_VALUE", "Product_Information.pdf", source_version, "ingredients unresolved in demo", "low")
  }

  # Manufacturing stage assumptions.
  manuf <- lci_cfg$manufacturing %||% list()
  m_elec <- to_num(manuf$electricity_kwh_per_1000kcal %||% NA_real_)
  m_ng <- to_num(manuf$natural_gas_mj_per_1000kcal %||% NA_real_)
  if (!is.finite(m_elec) || !is.finite(m_ng)) {
    if (lci_is_real_run_env()) stop("REAL_RUN requires manufacturing energy assumptions (electricity/natural gas)")
    li <- li + 1L
    ledger_rows[[li]] <- make_row(run_id, sys_id, "manufacturing", "manufacturing", "electricity_use", "input", NA_real_, "kWh", "NEEDS_SOURCE_VALUE", wb, source_version, "manufacturing electricity assumption missing", "low")
    li <- li + 1L
    ledger_rows[[li]] <- make_row(run_id, sys_id, "manufacturing", "manufacturing", "natural_gas_use", "input", NA_real_, "MJ", "NEEDS_SOURCE_VALUE", wb, source_version, "manufacturing gas assumption missing", "low")
  } else {
    li <- li + 1L
    ledger_rows[[li]] <- make_row(run_id, sys_id, "manufacturing", "manufacturing", "electricity_use", "input", m_elec, "kWh", "manufacturing_energy_assumption", wb, source_version, "configured manufacturing assumption", "med")
    li <- li + 1L
    ledger_rows[[li]] <- make_row(run_id, sys_id, "manufacturing", "manufacturing", "natural_gas_use", "input", m_ng, "MJ", "manufacturing_energy_assumption", wb, source_version, "configured manufacturing assumption", "med")
  }

  # Packaging stage using per-truck assumptions normalized by kcal_per_truck.
  pallets_max <- to_num(cfg$load_model$trailer$pallets_max %||% 26)
  pallet_tare_lb <- to_num(cfg$load_model$packaging$pallet_tare_lb$distribution$mode %||% NA_real_)
  case_tare_lb <- to_num(cfg$load_model$packaging$case_tare_lb[[sys_id]]$distribution$mode %||% NA_real_)
  units_per_truck <- to_num(sm$units_per_truck[[1]] %||% NA_real_)
  units_per_case <- to_num(sm$units_per_case_draw[[1]] %||% NA_real_)

  packaging_ok <- is.finite(per_fu) && is.finite(units_per_truck) && is.finite(units_per_case) && units_per_case > 0 && is.finite(pallet_tare_lb) && is.finite(case_tare_lb)
  if (packaging_ok) {
    cases_per_truck <- units_per_truck / units_per_case
    cardboard_kg <- cases_per_truck * case_tare_lb * 0.45359237 * per_fu
    pallet_wood_kg <- pallets_max * pallet_tare_lb * 0.45359237 * per_fu
    li <- li + 1L
    ledger_rows[[li]] <- make_row(run_id, sys_id, "packaging", "case_packaging", "cardboard_case_mass", "input", cardboard_kg, "kg", "packaging_case_tare", "test_kit.yaml", source_version, "case tare x cases per truck normalized", "med")
    li <- li + 1L
    ledger_rows[[li]] <- make_row(run_id, sys_id, "packaging", "pallet_packaging", "pallet_wood_mass", "input", pallet_wood_kg, "kg", "packaging_pallet_tare", "test_kit.yaml", source_version, "pallet tare x pallet count normalized", "med")
  } else {
    if (lci_is_real_run_env()) stop("REAL_RUN requires packaging assumptions and load outputs to compute packaging flows")
    li <- li + 1L
    ledger_rows[[li]] <- make_row(run_id, sys_id, "packaging", "packaging", "packaging_mass", "input", NA_real_, "kg", "NEEDS_SOURCE_VALUE", "test_kit.yaml", source_version, "packaging flow unresolved in demo", "low")
  }

  # Distribution stage: normalize route outputs to per 1000kcal.
  diesel_gal <- to_num(sm$diesel_gal_propulsion[[1]] %||% 0) + to_num(sm$diesel_gal_tru[[1]] %||% 0)
  elec_kwh <- to_num(sm$energy_kwh_propulsion[[1]] %||% 0) + to_num(sm$energy_kwh_tru[[1]] %||% 0)
  delivery_h <- to_num(sm$delivery_time_min[[1]] %||% sm$trip_duration_total_h[[1]] * 60) / 60
  d_drv <- to_num(sm$driver_driving_min[[1]] %||% NA_real_) / 60
  d_on <- to_num(sm$driver_on_duty_min[[1]] %||% NA_real_) / 60
  d_off <- to_num(sm$driver_off_duty_min[[1]] %||% NA_real_) / 60

  li <- li + 1L
  ledger_rows[[li]] <- make_row(run_id, sys_id, "distribution", "route_sim", "tractor_diesel", "input", diesel_gal * per_fu, "gal", "route_sim_distribution", file.path(bd, "summaries.csv"), source_version, "normalized by kcal_per_truck", "high")
  li <- li + 1L
  ledger_rows[[li]] <- make_row(run_id, sys_id, "distribution", "route_sim", "traction_electricity", "input", elec_kwh * per_fu, "kWh", "route_sim_distribution", file.path(bd, "summaries.csv"), source_version, "normalized by kcal_per_truck", "high")
  li <- li + 1L
  ledger_rows[[li]] <- make_row(run_id, sys_id, "distribution", "route_sim", "refrigeration_runtime", "input", delivery_h * per_fu, "h", "route_sim_distribution", file.path(bd, "summaries.csv"), source_version, "loaded-trip runtime proxy", "high")
  li <- li + 1L
  ledger_rows[[li]] <- make_row(run_id, sys_id, "distribution", "route_sim", "driver_driving_time", "input", d_drv * per_fu, "h", "route_sim_distribution", file.path(bd, "summaries.csv"), source_version, "viability flow", "high")
  li <- li + 1L
  ledger_rows[[li]] <- make_row(run_id, sys_id, "distribution", "route_sim", "driver_on_duty_time", "input", d_on * per_fu, "h", "route_sim_distribution", file.path(bd, "summaries.csv"), source_version, "viability flow", "high")
  li <- li + 1L
  ledger_rows[[li]] <- make_row(run_id, sys_id, "distribution", "route_sim", "driver_off_duty_time", "input", d_off * per_fu, "h", "route_sim_distribution", file.path(bd, "summaries.csv"), source_version, "viability flow", "high")

  # Placeholder lifecycle stages retained for boundary clarity.
  for (st in c("retail_storage", "household_storage", "eol")) {
    li <- li + 1L
    ledger_rows[[li]] <- make_row(run_id, sys_id, st, st, paste0(st, "_energy"), "input", NA_real_, "kWh", "NEEDS_SOURCE_VALUE", wb, source_version, "boundary stage placeholder", if (lci_is_real_run_env()) "med" else "low")
  }

  # Collect references for provenance.
  dref <- unique(data.frame(
    dataset_key = as.character(c(
      "route_sim_distribution", "manufacturing_energy_assumption", "packaging_case_tare", "packaging_pallet_tare",
      as.character(up$lci_key %||% character())
    )),
    source_file = as.character(c(file.path(bd, "summaries.csv"), wb, "test_kit.yaml", "test_kit.yaml", rep(wb, nrow(up)))),
    source_version = as.character(source_version),
    stringsAsFactors = FALSE
  ))
  dref <- dref[nzchar(dref$dataset_key), , drop = FALSE]
  dr_i <- dr_i + 1L
  all_dataset_refs[[dr_i]] <- dref
}

if (length(ledger_rows) == 0) stop("No ledger rows produced for selected bundles/product")
ledger <- do.call(rbind, ledger_rows)

# Enforce schema columns.
req_cols <- lci_required_inventory_columns()
missing_cols <- setdiff(req_cols, names(ledger))
if (length(missing_cols) > 0) {
  stop("Ledger missing required columns: ", paste(missing_cols, collapse = ", "))
}
ledger <- ledger[, req_cols, drop = FALSE]

# Currency / price policy lint.
lci_lint_forbidden_usd_from_lci(ledger, "inventory_ledger")

# Provenance manifest.
prov <- if (length(all_dataset_refs) > 0) unique(do.call(rbind, all_dataset_refs)) else data.frame()
if (nrow(prov) > 0) {
  prov$source_hash_md5 <- vapply(prov$source_file, lci_md5_or_na, character(1))
}
ledger_keys <- unique(as.character(ledger$dataset_key))
ledger_keys <- ledger_keys[nzchar(ledger_keys)]
if (length(ledger_keys) > 0) {
  missing_keys <- setdiff(ledger_keys, as.character(prov$dataset_key %||% character()))
  if (length(missing_keys) > 0) {
    add <- data.frame(
      dataset_key = as.character(missing_keys),
      source_file = NA_character_,
      source_version = NA_character_,
      source_hash_md5 = NA_character_,
      stringsAsFactors = FALSE
    )
    prov <- unique(rbind(prov, add))
  }
}

# Optional flow-cost extraction and process cards.
cost_summary <- data.frame()
first_params <- read_params(bundle_dirs[[1]])
cfg_first <- first_params$config %||% list()
lci_cfg_first <- cfg_first$lci %||% list()
wb_path <- as.character(lci_cfg_first$lci_workbook_path %||% "LCI.xlsx")

if (file.exists(wb_path)) {
  cost_res <- lci_extract_flow_costs_from_workbook(
    workbook_path = wb_path,
    raw_outdir = raw_costs_dir,
    coverage_threshold = as.numeric(opt$coverage_threshold)
  )
  cost_summary <- cost_res$summary

  major_process_keys <- names(lci_cfg_first$product_composition[[product_type]] %||% list())
  if (length(major_process_keys) == 0) {
    major_process_keys <- unique(as.character(ledger$dataset_key[ledger$stage == "ingredients"]))
  }
  process_map_path <- as.character(lci_cfg_first$process_key_map_path %||% file.path("data", "inputs", "lci_process_key_map.csv"))
  pmap <- if (file.exists(process_map_path)) utils::read.csv(process_map_path, stringsAsFactors = FALSE) else data.frame()

  for (pk in unique(major_process_keys)) {
    sheet_name <- pk
    if (nrow(pmap) > 0 && all(c("process_key", "sheet_name") %in% names(pmap))) {
      idx <- which(lci_normalize_key(pmap$process_key) == lci_normalize_key(pk))
      if (length(idx) > 0) sheet_name <- as.character(pmap$sheet_name[[idx[[1]]]])
    }
    inv <- tryCatch(lci_extract_inventory_flows(wb_path, sheet_name), error = function(e) data.frame())
    cst <- if (nrow(cost_summary) > 0) {
      raw_path <- as.character(cost_summary$raw_flow_costs_csv[lci_normalize_key(cost_summary$sheet_name) == lci_normalize_key(sheet_name)][[1]] %||% "")
      if (nzchar(raw_path) && file.exists(raw_path)) utils::read.csv(raw_path, stringsAsFactors = FALSE) else data.frame()
    } else {
      data.frame()
    }
    lci_write_process_card(
      out_dir = cards_dir,
      process_key = pk,
      sheet_name = sheet_name,
      dataset_key = pk,
      inv_df = inv,
      cost_df = cst,
      source_file = wb_path,
      source_version = as.character(lci_cfg_first$source_version %||% format(Sys.Date(), "%Y-%m-%d")),
      note = "Inventory from LCI sheet; costs are optional LCC and not consumer prices"
    )
  }
} else {
  message("WARN: LCI workbook not found; process cards and raw flow-cost extracts skipped")
}

summary_stage <- lci_build_stage_summary(ledger)

ledger_csv <- file.path(outdir, "inventory_ledger.csv")
ledger_json <- file.path(outdir, "inventory_ledger.json")
summary_csv <- file.path(outdir, "inventory_summary_by_stage.csv")
prov_csv <- file.path(outdir, "provenance_manifest.csv")
cost_csv <- file.path(outdir, "flow_cost_coverage_summary.csv")

utils::write.csv(ledger, ledger_csv, row.names = FALSE)
jsonlite::write_json(
  list(
    metadata = list(
      generated_at_utc = format(Sys.time(), tz = "UTC", usetz = TRUE),
      product_type = product_type,
      functional_unit_basis = fu_basis,
      currency_policy = "LCI flow costs are optional LCC values in EUR/EUR2005 style; never auto-converted to USD."
    ),
    rows = ledger
  ),
  ledger_json,
  pretty = TRUE,
  auto_unbox = TRUE,
  null = "null"
)
utils::write.csv(summary_stage, summary_csv, row.names = FALSE)
utils::write.csv(prov, prov_csv, row.names = FALSE)
if (nrow(cost_summary) > 0) utils::write.csv(cost_summary, cost_csv, row.names = FALSE)

# Final lint pass over outputs.
if (nrow(cost_summary) > 0) {
  lci_cost_df <- data.frame(dataset_key = "lci_cost_lcc", dummy = 1, stringsAsFactors = FALSE)
  names(lci_cost_df)[2] <- "dummy_metric"
  lci_lint_forbidden_usd_from_lci(lci_cost_df, "flow_cost_coverage_summary")
}

cat("Wrote", outdir, "\n")
