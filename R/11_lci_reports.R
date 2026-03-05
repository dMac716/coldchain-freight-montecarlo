`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

lci_is_real_run_env <- function() {
  v <- tolower(trimws(Sys.getenv("REAL_RUN", unset = "0")))
  v %in% c("1", "true", "yes", "y")
}

lci_required_inventory_columns <- function() {
  c(
    "run_id", "system_id", "stage", "process", "flow_name", "direction", "amount", "unit",
    "functional_unit_basis", "dataset_key", "source_file", "source_version", "assumption_notes", "confidence"
  )
}

lci_inventory_schema_rows <- function() {
  data.frame(
    column_name = c(
      "system_id", "stage", "process", "flow_name", "direction", "amount", "unit",
      "functional_unit_basis", "dataset_key", "source_file", "source_version", "assumption_notes", "confidence"
    ),
    required = c(rep("yes", 14)),
    allowed_values = c(
      "dry|refrigerated",
      "ingredients|manufacturing|packaging|distribution|retail_storage|household_storage|eol",
      "string",
      "string",
      "input|output",
      "numeric",
      "string",
      "per_1000kcal|per_kg_product",
      "string",
      "string",
      "string",
      "string",
      "high|med|low"
    ),
    stringsAsFactors = FALSE
  )
}

lci_normalize_key <- function(x) {
  gsub("[^a-z0-9]+", "", tolower(trimws(as.character(x %||% ""))))
}

lci_find_header_row <- function(mat, required_headers) {
  nr <- nrow(mat)
  if (nr == 0) return(NA_integer_)
  req <- tolower(trimws(required_headers))
  for (i in seq_len(nr)) {
    vals <- tolower(trimws(as.character(unlist(mat[i, , drop = TRUE]))))
    vals <- vals[nzchar(vals)]
    if (all(req %in% vals)) return(i)
  }
  NA_integer_
}

lci_parse_flow_cost_block <- function(sheet_df, sheet_name = "", section_headers = NULL) {
  if (is.null(section_headers)) {
    section_headers <- c(
      "flow properties", "impact assessment", "documentation", "social impacts",
      "administrative information", "allocation", "modeling and validation",
      "parameters", "general comment", "exchanges"
    )
  }
  if (nrow(sheet_df) == 0 || ncol(sheet_df) == 0) {
    return(list(rows = data.frame(), summary = data.frame(sheet_name = sheet_name, found = FALSE, stringsAsFactors = FALSE)))
  }
  mat <- as.data.frame(sheet_df, stringsAsFactors = FALSE)
  col1 <- tolower(trimws(as.character(mat[[1]])))
  start_idx <- which(col1 == "flow costs")
  if (length(start_idx) == 0) {
    return(list(rows = data.frame(), summary = data.frame(sheet_name = sheet_name, found = FALSE, stringsAsFactors = FALSE)))
  }
  block_start <- as.integer(start_idx[[1]])
  search_mat <- mat[seq.int(block_start + 1L, nrow(mat)), , drop = FALSE]
  hdr_req <- c("parameter", "flow", "inputs/outputs", "amount", "price", "overhead ratio", "cost")
  hdr_rel <- lci_find_header_row(search_mat, hdr_req)
  if (!is.finite(hdr_rel)) {
    return(list(rows = data.frame(), summary = data.frame(sheet_name = sheet_name, found = TRUE, parse_ok = FALSE, block_start_row = block_start, stringsAsFactors = FALSE)))
  }
  header_row <- block_start + hdr_rel
  headers <- tolower(trimws(as.character(unlist(mat[header_row, , drop = TRUE]))))

  find_col <- function(pattern) {
    idx <- which(grepl(pattern, headers))
    if (length(idx) == 0) return(NA_integer_)
    as.integer(idx[[1]])
  }

  c_parameter <- find_col("^parameter$")
  c_flow <- find_col("^flow$")
  c_io <- find_col("inputs/outputs")
  c_amount <- find_col("^amount$")
  c_price <- find_col("^price$")
  c_overhead <- find_col("overhead ratio")
  c_cost <- find_col("^cost$")
  c_units <- which(headers == "units")
  c_units_amount <- if (length(c_units) >= 1) as.integer(c_units[[1]]) else NA_integer_
  c_units_cost <- if (length(c_units) >= 2) as.integer(c_units[[2]]) else c_units_amount

  parse_num <- function(x) suppressWarnings(as.numeric(gsub(",", "", as.character(x))))

  rows <- list()
  ri <- 0L
  blank_streak <- 0L
  end_row <- nrow(mat)

  for (r in seq.int(header_row + 1L, nrow(mat))) {
    first_cell <- tolower(trimws(as.character(mat[[1]][[r]] %||% "")))
    if (nzchar(first_cell) && first_cell %in% section_headers) {
      end_row <- r - 1L
      break
    }

    flow_val <- trimws(as.character(mat[[c_flow]][[r]] %||% ""))
    io_val <- trimws(as.character(mat[[c_io]][[r]] %||% ""))
    if (!nzchar(flow_val) && !nzchar(io_val)) {
      blank_streak <- blank_streak + 1L
      if (blank_streak >= 3L) {
        end_row <- r - blank_streak
        break
      }
      next
    }
    blank_streak <- 0L

    ri <- ri + 1L
    rows[[ri]] <- data.frame(
      sheet_name = as.character(sheet_name),
      row_index = as.integer(r),
      parameter = as.character(mat[[c_parameter]][[r]] %||% ""),
      flow = as.character(flow_val),
      inputs_outputs = as.character(io_val),
      amount = parse_num(mat[[c_amount]][[r]]),
      amount_units = as.character(mat[[c_units_amount]][[r]] %||% ""),
      price = parse_num(mat[[c_price]][[r]]),
      price_units = as.character(mat[[c_units_cost]][[r]] %||% ""),
      overhead_ratio = parse_num(mat[[c_overhead]][[r]]),
      cost = parse_num(mat[[c_cost]][[r]]),
      stringsAsFactors = FALSE
    )
  }

  out_rows <- if (length(rows) > 0) do.call(rbind, rows) else data.frame()
  total_rows <- nrow(out_rows)
  nonzero_cost_rows <- if (total_rows > 0) sum(is.finite(out_rows$cost) & out_rows$cost != 0, na.rm = TRUE) else 0L
  cost_coverage <- if (total_rows > 0) nonzero_cost_rows / total_rows else 0
  summary <- data.frame(
    sheet_name = as.character(sheet_name),
    found = TRUE,
    parse_ok = TRUE,
    block_start_row = as.integer(block_start),
    header_row = as.integer(header_row),
    block_end_row = as.integer(end_row),
    total_rows = as.integer(total_rows),
    nonzero_cost_rows = as.integer(nonzero_cost_rows),
    cost_coverage = as.numeric(cost_coverage),
    cost_total_eur = if (total_rows > 0) sum(out_rows$cost, na.rm = TRUE) else NA_real_,
    pos_cost_total_eur = if (total_rows > 0) sum(out_rows$cost[out_rows$cost > 0], na.rm = TRUE) else NA_real_,
    stringsAsFactors = FALSE
  )

  list(rows = out_rows, summary = summary)
}

lci_extract_flow_costs_from_workbook <- function(workbook_path, raw_outdir, coverage_threshold = 0.25, sheet_subset = NULL) {
  if (!requireNamespace("readxl", quietly = TRUE)) {
    stop("readxl package is required for flow-cost extraction")
  }
  if (!file.exists(workbook_path)) {
    stop("Workbook not found: ", workbook_path)
  }
  dir.create(raw_outdir, recursive = TRUE, showWarnings = FALSE)

  sheets <- readxl::excel_sheets(workbook_path)
  if (!is.null(sheet_subset) && length(sheet_subset) > 0) {
    keep <- lci_normalize_key(sheets) %in% lci_normalize_key(sheet_subset)
    sheets <- sheets[keep]
  }

  all_rows <- list()
  all_summary <- list()
  i <- 0L
  j <- 0L
  for (sh in sheets) {
    dat <- readxl::read_excel(workbook_path, sheet = sh, col_names = FALSE)
    parsed <- lci_parse_flow_cost_block(dat, sheet_name = sh)
    sm <- parsed$summary
    if (!"parse_ok" %in% names(sm)) sm$parse_ok <- FALSE
    sm <- lci_apply_flow_cost_coverage_policy(sm, coverage_threshold = coverage_threshold, warn_prefix = paste0("sheet=", sh))

    if (nrow(parsed$rows) > 0) {
      i <- i + 1L
      all_rows[[i]] <- parsed$rows
      out_csv <- file.path(raw_outdir, paste0(gsub("[^A-Za-z0-9._-]+", "_", sh), "__flow_costs.csv"))
      utils::write.csv(parsed$rows, out_csv, row.names = FALSE)
      sm$raw_flow_costs_csv <- out_csv
    } else {
      sm$raw_flow_costs_csv <- NA_character_
    }

    j <- j + 1L
    all_summary[[j]] <- sm
  }

  list(
    rows = if (length(all_rows) > 0) do.call(rbind, all_rows) else data.frame(),
    summary = if (length(all_summary) > 0) do.call(rbind, all_summary) else data.frame()
  )
}

lci_apply_flow_cost_coverage_policy <- function(summary_df, coverage_threshold = 0.25, warn_prefix = "") {
  if (nrow(summary_df) == 0) return(summary_df)
  d <- summary_df
  d$coverage_threshold <- as.numeric(coverage_threshold)
  d$lcc_total_included <- as.integer(
    isTRUE(d$parse_ok[[1]]) &&
      is.finite(d$cost_coverage[[1]]) &&
      d$cost_coverage[[1]] >= coverage_threshold
  )
  if (!isTRUE(d$lcc_total_included[[1]])) {
    d$cost_total_eur <- NA_real_
    d$pos_cost_total_eur <- NA_real_
    if (isTRUE(d$found[[1]]) && isTRUE(d$parse_ok[[1]])) {
      msg <- "WARN: Flow cost coverage low; LCC totals omitted"
      if (nzchar(warn_prefix)) msg <- paste0(msg, " (", warn_prefix, ")")
      warning(msg, call. = FALSE)
    }
  }
  d
}

lci_extract_inventory_flows <- function(workbook_path, sheet_name) {
  if (!requireNamespace("readxl", quietly = TRUE)) return(data.frame())
  if (!file.exists(workbook_path)) return(data.frame())
  dat <- readxl::read_excel(workbook_path, sheet = sheet_name, col_names = FALSE)
  if (nrow(dat) == 0) return(data.frame())
  mat <- as.data.frame(dat, stringsAsFactors = FALSE)
  h <- lci_find_header_row(mat, c("flow", "amount", "unit"))
  if (!is.finite(h)) return(data.frame())
  headers <- tolower(trimws(as.character(unlist(mat[h, , drop = TRUE]))))
  idx_flow <- which(headers == "flow")
  idx_amount <- which(headers == "amount")
  idx_unit <- which(headers == "unit" | headers == "units")
  idx_io <- which(grepl("inputs/outputs", headers))
  if (length(idx_flow) == 0 || length(idx_amount) == 0 || length(idx_unit) == 0) return(data.frame())
  parse_num <- function(x) suppressWarnings(as.numeric(gsub(",", "", as.character(x))))
  rows <- list()
  ri <- 0L
  for (r in seq.int(h + 1L, nrow(mat))) {
    flow <- trimws(as.character(mat[[idx_flow[[1]]]][[r]] %||% ""))
    amt <- parse_num(mat[[idx_amount[[1]]]][[r]])
    unit <- trimws(as.character(mat[[idx_unit[[1]]]][[r]] %||% ""))
    if (!nzchar(flow) && !is.finite(amt) && !nzchar(unit)) break
    if (!nzchar(flow) || !is.finite(amt)) next
    ri <- ri + 1L
    rows[[ri]] <- data.frame(
      row_index = as.integer(r),
      flow_name = as.character(flow),
      direction = if (length(idx_io) > 0) as.character(trimws(as.character(mat[[idx_io[[1]]]][[r]] %||% ""))) else NA_character_,
      amount = as.numeric(amt),
      unit = as.character(unit),
      stringsAsFactors = FALSE
    )
  }
  if (length(rows) == 0) return(data.frame())
  do.call(rbind, rows)
}

lci_resolve_bundle_dirs <- function(bundle_dir) {
  if (file.exists(file.path(bundle_dir, "summaries.csv"))) {
    return(normalizePath(bundle_dir, winslash = "/", mustWork = TRUE))
  }
  d <- list.dirs(bundle_dir, full.names = TRUE, recursive = FALSE)
  d[file.exists(file.path(d, "summaries.csv"))]
}

lci_md5_or_na <- function(path) {
  if (!file.exists(path)) return(NA_character_)
  as.character(unname(tools::md5sum(path)[[1]]))
}

lci_lint_forbidden_usd_from_lci <- function(df, df_name = "") {
  if (is.null(df) || nrow(df) == 0) return(invisible(TRUE))
  has_usd <- any(grepl("_usd_", names(df), ignore.case = TRUE))
  if (!has_usd) return(invisible(TRUE))
  dkey <- tolower(as.character(df$dataset_key %||% ""))
  if (any(grepl("lci_cost|flow_cost|lcc", dkey), na.rm = TRUE)) {
    stop("Forbidden output: *_usd_* columns derived from LCI price fields in ", df_name)
  }
  invisible(TRUE)
}

lci_write_process_card <- function(out_dir, process_key, sheet_name, dataset_key, inv_df, cost_df, source_file, source_version, note = "") {
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  slug <- gsub("[^A-Za-z0-9._-]+", "_", process_key)
  inv_out <- file.path(out_dir, paste0(slug, "_inventory.csv"))
  cost_out <- file.path(out_dir, paste0(slug, "_costs.csv"))
  md_out <- file.path(out_dir, paste0(slug, ".md"))

  inv_top <- inv_df
  if (nrow(inv_top) > 0) {
    inv_top <- inv_top[order(abs(inv_top$amount), decreasing = TRUE), , drop = FALSE]
    inv_top <- utils::head(inv_top, 10)
  }

  utils::write.csv(inv_top, inv_out, row.names = FALSE)
  utils::write.csv(cost_df, cost_out, row.names = FALSE)

  lines <- c(
    paste0("# Process Card: ", process_key),
    "",
    paste0("- dataset_key: `", dataset_key, "`"),
    paste0("- sheet_name: `", sheet_name, "`"),
    paste0("- source_file: `", source_file, "`"),
    paste0("- source_version: `", source_version, "`"),
    paste0("- last_updated_utc: `", format(Sys.time(), tz = "UTC", usetz = TRUE), "`"),
    if (nzchar(note)) paste0("- assumptions/proxies: ", note) else "- assumptions/proxies: none",
    "",
    "## Key Inventory Flows (Top N)",
    if (nrow(inv_top) > 0) paste0("- rows: ", nrow(inv_top)) else "- none parsed",
    "",
    "## Costs (LCC optional)",
    if (nrow(cost_df) > 0) paste0("- raw flow-cost rows: ", nrow(cost_df), " (currency basis as provided, typically EUR/EUR2005)") else "- no flow-cost block parsed"
  )
  writeLines(lines, md_out)

  list(inventory_csv = inv_out, costs_csv = cost_out, markdown = md_out)
}

lci_build_stage_summary <- function(ledger_df) {
  if (nrow(ledger_df) == 0) return(data.frame())
  x <- ledger_df[is.finite(ledger_df$amount), c("run_id", "stage", "unit", "amount"), drop = FALSE]
  if (nrow(x) == 0) return(data.frame())
  run_stage <- stats::aggregate(amount ~ run_id + stage + unit, data = x, FUN = sum)
  g <- split(run_stage, list(run_stage$stage, run_stage$unit), drop = TRUE)
  out <- lapply(g, function(d) {
    vals <- as.numeric(d$amount)
    data.frame(
      stage = as.character(d$stage[[1]]),
      unit = as.character(d$unit[[1]]),
      n_runs = nrow(d),
      p05 = as.numeric(stats::quantile(vals, 0.05, na.rm = TRUE, names = FALSE)),
      p50 = as.numeric(stats::quantile(vals, 0.50, na.rm = TRUE, names = FALSE)),
      p95 = as.numeric(stats::quantile(vals, 0.95, na.rm = TRUE, names = FALSE)),
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, out)
}
