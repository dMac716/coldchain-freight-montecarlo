#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
})
if (!requireNamespace("data.table", quietly = TRUE)) stop("data.table package required")
data.table::setDTthreads(1L)

script_file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
script_path <- if (length(script_file_arg) > 0) sub("^--file=", "", script_file_arg[[1]]) else "tools/run_route_sim_mc.R"
script_path <- normalizePath(script_path, winslash = "/", mustWork = TRUE)
script_dir <- dirname(script_path)
repo_root <- normalizePath(file.path(script_dir, ".."), winslash = "/", mustWork = TRUE)
Sys.setenv(COLDCHAIN_REPO_ROOT = repo_root)

resolve_repo_path <- function(path, kind = c("file", "dir"), must_work = TRUE) {
  kind <- match.arg(kind)
  raw <- trimws(as.character(path))
  if (!nzchar(raw)) return(raw)
  expanded <- path.expand(raw)
  is_absolute <- grepl("^(/|[A-Za-z]:[/\\\\])", expanded)
  candidates <- unique(c(expanded, if (!is_absolute) file.path(repo_root, raw) else NULL))
  exists_fn <- if (identical(kind, "dir")) dir.exists else file.exists
  for (candidate in candidates) {
    if (exists_fn(candidate)) {
      return(normalizePath(candidate, winslash = "/", mustWork = TRUE))
    }
  }
  if (isTRUE(must_work)) {
    stop(
      sprintf(
        "%s not found: %s. Checked: %s",
        tools::toTitleCase(kind),
        raw,
        paste(candidates, collapse = ", ")
      )
    )
  }
  normalizePath(candidates[[length(candidates)]], winslash = "/", mustWork = FALSE)
}

# Keep BLAS/OpenMP from oversubscribing shared hosts.
Sys.setenv(
  OMP_NUM_THREADS = "1",
  OPENBLAS_NUM_THREADS = "1",
  MKL_NUM_THREADS = "1",
  VECLIB_MAXIMUM_THREADS = "1",
  NUMEXPR_NUM_THREADS = "1"
)

source_files <- c(
  list.files(file.path(repo_root, "R"), pattern = "\\.R$", full.names = TRUE),
  list.files(file.path(repo_root, "R", "io"), pattern = "\\.R$", full.names = TRUE),
  list.files(file.path(repo_root, "R", "sim"), pattern = "\\.R$", full.names = TRUE)
)
source_files <- sort(unique(source_files))
for (f in source_files) source(f, local = FALSE)

read_cfg <- function(path) {
  if (!requireNamespace("yaml", quietly = TRUE)) stop("yaml package required for route sim config")
  y <- yaml::read_yaml(path)
  if (!is.null(y$test_kit)) y$test_kit else y
}

sanitize_id <- function(x) gsub("[^A-Za-z0-9._-]+", "_", as.character(x))

safe_nonneg <- function(x, default = 0) {
  v <- suppressWarnings(as.numeric(x))
  if (!is.finite(v) || v < 0) return(as.numeric(default))
  as.numeric(v)
}

safe_posint <- function(x, default = NA_integer_) {
  v <- suppressWarnings(as.integer(x))
  if (!is.finite(v) || v <= 0L) return(as.integer(default))
  as.integer(v)
}

record_to_single_row <- function(x) {
  if (is.null(x)) return(data.frame(stringsAsFactors = FALSE))
  if (!is.list(x)) x <- as.list(x)
  out <- list()
  nms <- names(x)
  if (is.null(nms)) nms <- paste0("v", seq_along(x))
  for (i in seq_along(x)) {
    v <- x[[i]]
    nm <- nms[[i]]
    if (is.null(v) || length(v) == 0) {
      out[[nm]] <- NA
      next
    }
    if (is.list(v)) {
      out[[nm]] <- jsonlite::toJSON(v, auto_unbox = TRUE, null = "null")
      next
    }
    if (length(v) == 1) {
      out[[nm]] <- v
      next
    }
    vv <- as.character(v)
    vv <- vv[nzchar(vv) & !is.na(vv)]
    out[[nm]] <- if (length(vv) > 0) paste(unique(vv), collapse = "|") else NA_character_
  }
  as.data.frame(out, stringsAsFactors = FALSE)
}

is_missing_scalar <- function(v) {
  if (is.null(v) || length(v) == 0) return(TRUE)
  vv <- suppressWarnings(as.character(v[[1]]))
  if (is.na(vv)) return(TRUE)
  vv <- trimws(vv)
  if (!nzchar(vv)) return(TRUE)
  tolower(vv) %in% c("na", "null", "none")
}

coalesce_scalar <- function(primary, fallback = NA_character_) {
  if (is_missing_scalar(list(primary))) as.character(fallback %||% NA_character_) else as.character(primary)
}

lookup_retail_id_by_route <- function(route_id, routes_df = NULL) {
  rid <- trimws(as.character(route_id %||% ""))
  if (!nzchar(rid)) return("")
  if (is.null(routes_df) || !is.data.frame(routes_df) || nrow(routes_df) == 0) return("")
  if (!all(c("route_id", "retail_id") %in% names(routes_df))) return("")
  idx <- which(as.character(routes_df$route_id) == rid)
  if (length(idx) == 0) return("")
  vals <- as.character(routes_df$retail_id[idx])
  vals <- vals[!is.na(vals) & nzchar(trimws(vals))]
  if (length(vals) == 0) return("")
  as.character(vals[[1]])
}

materialize_paired_origin_bundle <- function(bundle_root, pair_id, member_records, routes_df = NULL) {
  if (length(member_records) < 2) return(invisible(NULL))

  pair_dir <- file.path(bundle_root, paste0("pair_", sanitize_id(pair_id)))
  dir.create(pair_dir, recursive = TRUE, showWarnings = FALSE)

  member_cap <- length(member_records)
  run_rows <- vector("list", member_cap)
  summary_rows <- vector("list", member_cap)
  art_rows <- vector("list", member_cap)
  ri <- 0L
  si <- 0L
  ai <- 0L
  member_run_ids <- character(member_cap)
  member_run_n <- 0L
  for (m in member_records) {
    if (is.null(m) || !is.list(m)) next
    rr <- m$run_record
    sm <- m$summary_record
    mr <- m$mc_row
    aj <- m$artifact_record
    rid <- as.character(rr$run_id %||% NA_character_)
    if (is.list(rr) && !is.null(rr$run_id) && nzchar(rid)) {
      member_run_n <- member_run_n + 1L
      member_run_ids[[member_run_n]] <- rid
      ri <- ri + 1L
      rr_df <- record_to_single_row(rr)
      rr_df$run_id <- rid
      if (!"pair_id" %in% names(rr_df) || !nzchar(as.character(rr_df$pair_id[[1]] %||% ""))) rr_df$pair_id <- as.character(pair_id)
      if (!"traffic_mode" %in% names(rr_df)) {
        rr_df$traffic_mode <- if (!is.null(sm) && nrow(sm) > 0 && "traffic_mode" %in% names(sm)) as.character(sm$traffic_mode[[1]]) else NA_character_
      }
      if (!"facility_id" %in% names(rr_df) || is_missing_scalar(rr_df$facility_id)) {
        rr_df$facility_id <- if (!is.null(sm) && nrow(sm) > 0 && "facility_id" %in% names(sm) && !is_missing_scalar(sm$facility_id)) {
          as.character(sm$facility_id[[1]])
        } else if (!is.null(mr) && nrow(mr) > 0 && "facility_id" %in% names(mr) && !is_missing_scalar(mr$facility_id)) {
          as.character(mr$facility_id[[1]])
        } else {
          NA_character_
        }
      }
      if (!"retail_id" %in% names(rr_df) || is_missing_scalar(rr_df$retail_id)) {
        rr_df$retail_id <- if (!is.null(sm) && nrow(sm) > 0 && "retail_id" %in% names(sm) && !is_missing_scalar(sm$retail_id)) {
          as.character(sm$retail_id[[1]])
        } else if (!is.null(mr) && nrow(mr) > 0 && "retail_id" %in% names(mr) && !is_missing_scalar(mr$retail_id)) {
          as.character(mr$retail_id[[1]])
        } else if (!is_missing_scalar(rr_df$route_id)) {
          lookup_retail_id_by_route(rr_df$route_id[[1]], routes_df = routes_df)
        } else {
          ""
        }
      }
      if (!"powertrain" %in% names(rr_df) || is_missing_scalar(rr_df$powertrain)) {
        rr_df$powertrain <- if (!is.null(sm) && nrow(sm) > 0 && "powertrain" %in% names(sm) && !is_missing_scalar(sm$powertrain)) {
          as.character(sm$powertrain[[1]])
        } else if (!is.null(mr) && nrow(mr) > 0 && "powertrain" %in% names(mr) && !is_missing_scalar(mr$powertrain)) {
          as.character(mr$powertrain[[1]])
        } else {
          NA_character_
        }
      }
      if (!"route_id" %in% names(rr_df)) rr_df$route_id <- as.character(NA)
      run_rows[[ri]] <- rr_df
    }
    if (!is.null(sm) && nrow(sm) > 0) {
      si <- si + 1L
      summary_rows[[si]] <- sm
    }
    if (!is.null(aj) && nrow(aj) > 0) {
      aj$member_run_id <- rid
      ai <- ai + 1L
      art_rows[[ai]] <- aj
    }
  }

  if (member_run_n > 0L) member_run_ids <- member_run_ids[seq_len(member_run_n)] else member_run_ids <- character()
  if (ri == 0L || si == 0L) return(invisible(NULL))
  runs_df <- as.data.frame(data.table::rbindlist(run_rows[seq_len(ri)], fill = TRUE, use.names = TRUE))
  sums_df <- as.data.frame(data.table::rbindlist(summary_rows[seq_len(si)], fill = TRUE, use.names = TRUE))
  arts_df <- if (ai > 0L) as.data.frame(data.table::rbindlist(art_rows[seq_len(ai)], fill = TRUE, use.names = TRUE)) else data.frame()

  runs_jsonl <- file.path(pair_dir, "runs.jsonl")
  con <- file(runs_jsonl, open = "wt")
  on.exit(close(con), add = TRUE)
  for (i in seq_len(nrow(runs_df))) {
    writeLines(jsonlite::toJSON(as.list(runs_df[i, , drop = FALSE]), auto_unbox = TRUE, null = "null"), con = con)
  }

  data.table::fwrite(runs_df, file.path(pair_dir, "runs.csv"))
  data.table::fwrite(sums_df, file.path(pair_dir, "summaries.csv"))
  jsonlite::write_json(
    list(
      pair_id = as.character(pair_id),
      run_ids = as.character(member_run_ids),
      bundle_member_count = as.integer(length(member_run_ids)),
      created_at_utc = as.character(format(Sys.time(), tz = "UTC", usetz = TRUE)),
      artifacts = arts_df
    ),
    path = file.path(pair_dir, "artifacts.json"),
    pretty = TRUE,
    auto_unbox = TRUE,
    null = "null"
  )
  jsonlite::write_json(
    list(
      pair_id = as.character(pair_id),
      paired_origin_networks = TRUE,
      scenario_id = if ("scenario_id" %in% names(sums_df)) as.character(sums_df$scenario_id[[1]]) else if ("scenario" %in% names(sums_df)) as.character(sums_df$scenario[[1]]) else NA_character_,
      origin_networks = sort(unique(as.character(sums_df$origin_network %||% NA_character_))),
      member_runs_path = "runs.csv"
    ),
    path = file.path(pair_dir, "params.json"),
    pretty = TRUE,
    auto_unbox = TRUE,
    null = "null"
  )
  manifest_powertrain <- if ("powertrain" %in% names(sums_df)) {
    as.character(sums_df$powertrain[[1]] %||% NA_character_)
  } else if ("powertrain" %in% names(runs_df)) {
    as.character(runs_df$powertrain[[1]] %||% NA_character_)
  } else {
    NA_character_
  }
  jsonlite::write_json(
    list(
      pair_id = as.character(pair_id),
      origin_networks = sort(unique(as.character(runs_df$origin_network %||% NA_character_))),
      traffic_modes = sort(unique(as.character(runs_df$traffic_mode %||% NA_character_))),
      scenario_id = if ("scenario_id" %in% names(sums_df)) as.character(sums_df$scenario_id[[1]]) else NA_character_,
      scenario = if ("scenario" %in% names(sums_df)) as.character(sums_df$scenario[[1]]) else NA_character_,
      powertrain = manifest_powertrain,
      seed = suppressWarnings(as.integer(gsub("^.*_seed_([0-9]+).*$", "\\1", as.character(pair_id)))),
      member_count = nrow(runs_df)
    ),
    path = file.path(pair_dir, "pair_manifest.json"),
    pretty = TRUE,
    auto_unbox = TRUE,
    null = "null"
  )
  invisible(pair_dir)
}

assert_pair_bundle_integrity <- function(pair_dir, expected_traffic_mode = NA_character_) {
  runs_path <- file.path(pair_dir, "runs.csv")
  if (!file.exists(runs_path)) stop("Pair integrity failed: missing runs.csv at ", pair_dir)
  d <- data.table::fread(runs_path, showProgress = FALSE)
  if (nrow(d) != 2L) stop("Pair integrity failed: expected 2 members, got ", nrow(d), " at ", pair_dir)
  if (!"origin_network" %in% names(d)) stop("Pair integrity failed: origin_network missing at ", pair_dir)
  origins <- sort(unique(as.character(d$origin_network)))
  exp_origins <- c("dry_factory_set", "refrigerated_factory_set")
  if (!(length(origins) == 2L && all(origins %in% exp_origins))) {
    stop("Pair integrity failed: unexpected origin labels ", paste(origins, collapse = ","), " at ", pair_dir)
  }
  if ("traffic_mode" %in% names(d) && is.finite(nchar(as.character(expected_traffic_mode))) && nzchar(as.character(expected_traffic_mode))) {
    tm <- unique(as.character(d$traffic_mode))
    if (!(length(tm) == 1L && identical(tm[[1]], as.character(expected_traffic_mode)))) {
      stop("Pair integrity failed: unexpected traffic_mode at ", pair_dir)
    }
  }
  invisible(TRUE)
}

opt <- parse_args(OptionParser(option_list = list(
  make_option(c("--config"), type = "character", default = "test_kit.yaml"),
  make_option(c("--data_path"), type = "character", default = ""),
  make_option(c("--map_path"), type = "character", default = ""),
  make_option(c("--routes"), type = "character", default = ""),
  make_option(c("--elevation"), type = "character", default = ""),
  make_option(c("--facility_id"), type = "character", default = "FACILITY_REFRIG_ENNIS"),
  make_option(c("--scenario"), type = "character", default = "route_sim_demo"),
  make_option(c("--powertrain"), type = "character", default = "bev"),
  make_option(c("--product_type"), type = "character", default = ""),
  make_option(c("--reefer_state"), type = "character", default = "auto"),
  make_option(c("--origin_network"), type = "character", default = ""),
  make_option(c("--paired_origin_networks"), type = "character", default = "false"),
  make_option(c("--traffic_mode"), type = "character", default = "stochastic"),
  make_option(c("--paired_traffic_modes"), type = "character", default = "false"),
  make_option(c("--scenario_id"), type = "character", default = ""),
  make_option(c("--scenario_test_matrix"), type = "character", default = "config/scenario_test_matrix.csv"),
  make_option(c("--facility_id_dry"), type = "character", default = "FACILITY_DRY_TOPEKA"),
  make_option(c("--facility_id_refrigerated"), type = "character", default = "FACILITY_REFRIG_ENNIS"),
  make_option(c("--trip_leg"), type = "character", default = "outbound"),
  make_option(c("--n"), type = "integer", default = 20L),
  make_option(c("--seed"), type = "integer", default = 123),
  make_option(c("--duration_hours"), type = "double", default = NA_real_),
  make_option(c("--bundle_root"), type = "character", default = "outputs/run_bundle"),
  make_option(c("--stations"), type = "character", default = ""),
  make_option(c("--plans"), type = "character", default = ""),
  make_option(c("--charger_state_case"), type = "character", default = ""),
  make_option(c("--summary_out"), type = "character", default = "outputs/summaries/route_sim_summary.csv"),
  make_option(c("--runs_out"), type = "character", default = ""),
  make_option(c("--progress_file"), type = "character", default = ""),
  make_option(c("--worker_label"), type = "character", default = ""),
  make_option(c("--throttle_seconds"), type = "double", default = 0),
  make_option(c("--batch_size"), type = "integer", default = 50L),
  make_option(c("--artifact_mode"), type = "character", default = "full"),
  make_option(c("--write_tracks"), type = "character", default = "true"),
  make_option(c("--write_events"), type = "character", default = "true"),
  make_option(c("--write_charge_details"), type = "character", default = "true"),
  make_option(c("--write_run_bundle"), type = "character", default = "true"),
  make_option(c("--compress_tracks"), type = "character", default = "true"),
  make_option(c("--memory_limit_mb"), type = "double", default = NA_real_),
  make_option(c("--memory_log_every_runs"), type = "integer", default = NA_integer_),
  make_option(c("--gc_every_runs"), type = "integer", default = NA_integer_),
  make_option(c("--memory_profile_out"), type = "character", default = ""),
  make_option(c("--memory_summary_out"), type = "character", default = ""),
  make_option(c("--runtime_summary_out"), type = "character", default = "")
)))

opt$config <- resolve_repo_path(opt$config, kind = "file", must_work = TRUE)
cfg <- read_cfg(opt$config)
if (nzchar(as.character(opt$charger_state_case %||% ""))) {
  if (is.null(cfg$charging)) cfg$charging <- list()
  cfg$charging$charger_state_case <- as.character(opt$charger_state_case)
}
data_path <- if (nzchar(opt$data_path)) {
  resolve_repo_path(opt$data_path, kind = "dir", must_work = TRUE)
} else {
  resolve_repo_path(
    as.character(cfg$paths$data_path %||% Sys.getenv("ROUTE_SIM_DATA_PATH", unset = file.path(repo_root, "data", "derived"))),
    kind = "dir",
    must_work = TRUE
  )
}
map_path <- if (nzchar(opt$map_path)) {
  resolve_repo_path(opt$map_path, kind = "dir", must_work = TRUE)
} else {
  resolve_repo_path(
    as.character(cfg$paths$map_path %||% Sys.getenv("ROUTE_SIM_MAP_PATH", unset = file.path(repo_root, "sources", "data", "osm"))),
    kind = "dir",
    must_work = FALSE
  )
}
if (!dir.exists(data_path)) {
  stop("Data path does not exist: ", data_path, ". Set --data_path or cfg$paths$data_path.")
}
if (!dir.exists(map_path)) {
  warning("Map path does not exist: ", map_path)
}
parse_csv_tokens <- function(x) {
  raw <- as.character(x %||% "")
  if (!nzchar(raw)) return(character())
  parts <- trimws(unlist(strsplit(raw, ",")))
  parts[nzchar(parts)]
}
parse_bool_flag <- function(x, default = TRUE) {
  raw <- tolower(trimws(as.character(x %||% "")))
  if (!nzchar(raw)) return(isTRUE(default))
  if (raw %in% c("1", "true", "yes", "y")) return(TRUE)
  if (raw %in% c("0", "false", "no", "n")) return(FALSE)
  stop("Boolean flag must be one of true/false/1/0/yes/no; got: ", as.character(x))
}
parse_reefer_state <- function(x) {
  raw <- tolower(trimws(as.character(x %||% "auto")))
  if (!nzchar(raw) || raw %in% c("auto", "default")) return(list(state = "auto", cold_chain_required = NA))
  if (raw %in% c("on", "true", "yes", "1")) return(list(state = "on", cold_chain_required = TRUE))
  if (raw %in% c("off", "false", "no", "0")) return(list(state = "off", cold_chain_required = FALSE))
  stop("--reefer_state must be one of: auto, on, off")
}
cli_has_flag <- function(flag_name) {
  args <- commandArgs(trailingOnly = TRUE)
  any(startsWith(args, paste0(flag_name, "=")) | args == flag_name)
}

parse_pair_flag_or_list <- function(x, valid_values = NULL) {
  raw <- as.character(x %||% "")
  low <- tolower(trimws(raw))
  if (low %in% c("", "0", "false", "no", "n")) return(list(enabled = FALSE, values = character()))
  if (low %in% c("1", "true", "yes", "y")) return(list(enabled = TRUE, values = character()))
  vals <- parse_csv_tokens(raw)
  if (length(vals) == 0) return(list(enabled = FALSE, values = character()))
  vals_low <- tolower(vals)
  if (!is.null(valid_values)) {
    bad <- setdiff(vals_low, valid_values)
    if (length(bad) > 0) stop("Unsupported paired values: ", paste(bad, collapse = ", "))
  }
  list(enabled = TRUE, values = vals_low)
}

origin_pair_arg <- parse_pair_flag_or_list(
  opt$paired_origin_networks,
  valid_values = c("dry_factory_set", "refrigerated_factory_set")
)
traffic_pair_arg <- parse_pair_flag_or_list(
  opt$paired_traffic_modes,
  valid_values = c("stochastic", "freeflow")
)
paired_origin_networks <- isTRUE(origin_pair_arg$enabled)
paired_traffic_modes <- isTRUE(traffic_pair_arg$enabled)
traffic_mode_input <- tolower(as.character(opt$traffic_mode %||% "stochastic"))
if (!traffic_mode_input %in% c("stochastic", "freeflow")) {
  stop("--traffic_mode must be one of: stochastic, freeflow")
}
infer_product_type <- function() {
  if (nzchar(opt$product_type)) return(tolower(opt$product_type))
  sc <- tolower(opt$scenario)
  if (grepl("dry", sc, fixed = TRUE)) return("dry")
  if (grepl("refriger", sc, fixed = TRUE)) return("refrigerated")
  "refrigerated"
}
product_type_for_origin <- function(origin_network_label) {
  # In paired-origin distribution studies, origin label encodes scenario row:
  # dry_factory_set => dry, refrigerated_factory_set => refrigerated.
  if (isTRUE(paired_origin_networks) && !nzchar(opt$product_type)) {
    o <- tolower(trimws(as.character(origin_network_label %||% "")))
    if (identical(o, "dry_factory_set")) return("dry")
    if (identical(o, "refrigerated_factory_set")) return("refrigerated")
  }
  if (nzchar(opt$product_type)) return(tolower(opt$product_type))
  infer_product_type()
}
infer_origin_network <- function() {
  if (nzchar(opt$origin_network)) return(tolower(opt$origin_network))
  sc <- tolower(opt$scenario)
  if (grepl("from_dry", sc, fixed = TRUE) || grepl("dry_factory_set", sc, fixed = TRUE)) return("dry_factory_set")
  if (grepl("from_reefer", sc, fixed = TRUE) || grepl("refrigerated_factory_set", sc, fixed = TRUE)) return("refrigerated_factory_set")
  NA_character_
}
product_type_resolved <- infer_product_type()
reefer_state_arg <- parse_reefer_state(opt$reefer_state)
origin_network_single <- infer_origin_network()
scenario_matrix_path <- resolve_repo_path(as.character(opt$scenario_test_matrix %||% ""), kind = "file", must_work = FALSE)
scenario_matrix <- data.frame()
if (nzchar(scenario_matrix_path) && file.exists(scenario_matrix_path)) {
  scenario_matrix <- data.table::fread(scenario_matrix_path, showProgress = FALSE, fill = TRUE)
  scenario_matrix <- as.data.frame(scenario_matrix, stringsAsFactors = FALSE)
  if (nrow(scenario_matrix) > 0) {
    for (cn in c("scenario_id", "scenario", "product_type", "powertrain", "origin_network", "traffic_mode",
                 "cold_chain_required", "facility_id", "retail_id", "trip_leg", "units_per_case_policy",
                 "case_geometry_policy", "load_assignment_policy", "artifact_mode", "notes")) {
      if (!cn %in% names(scenario_matrix)) scenario_matrix[[cn]] <- NA
    }
  }
}
resolve_scenario_meta <- function(scenario, product_type, powertrain, origin_network, traffic_mode, trip_leg) {
  defaults <- list(
    scenario_id = if (nzchar(as.character(opt$scenario_id %||% ""))) as.character(opt$scenario_id) else as.character(scenario),
    facility_id = NA_character_,
    retail_id = NA_character_,
    trip_leg = as.character(trip_leg),
    units_per_case_policy = if (tolower(as.character(product_type)) == "refrigerated") "discrete_4_5_6_centered_5" else "fixed_2",
    case_geometry_policy = if (tolower(as.character(product_type)) == "refrigerated") "derived_from_unit_dims_and_pack_pattern" else "fixed_carton_dims_24x16x6",
    load_assignment_policy = "full_truckload",
    artifact_mode = as.character(tolower(trimws(as.character(opt$artifact_mode %||% "full")))),
    notes = NA_character_
  )
  if (!is.data.frame(scenario_matrix) || nrow(scenario_matrix) == 0) return(defaults)
  d <- scenario_matrix
  if (nzchar(as.character(opt$scenario_id %||% "")) && "scenario_id" %in% names(d)) {
    d <- d[tolower(as.character(d$scenario_id)) == tolower(as.character(opt$scenario_id)), , drop = FALSE]
  } else {
    keep_wild <- function(col, value) {
      v <- tolower(trimws(as.character(col)))
      is.na(v) | !nzchar(v) | v == tolower(trimws(as.character(value)))
    }
    if ("scenario" %in% names(d)) d <- d[keep_wild(d$scenario, scenario), , drop = FALSE]
    if ("product_type" %in% names(d)) d <- d[keep_wild(d$product_type, product_type), , drop = FALSE]
    if ("powertrain" %in% names(d)) d <- d[keep_wild(d$powertrain, powertrain), , drop = FALSE]
    if ("origin_network" %in% names(d)) d <- d[keep_wild(d$origin_network, origin_network), , drop = FALSE]
    if ("traffic_mode" %in% names(d)) d <- d[keep_wild(d$traffic_mode, traffic_mode), , drop = FALSE]
    if ("trip_leg" %in% names(d)) d <- d[keep_wild(d$trip_leg, trip_leg), , drop = FALSE]
  }
  if (nrow(d) == 0) return(defaults)
  r <- d[1, , drop = FALSE]
  list(
    scenario_id = as.character(r$scenario_id[[1]] %||% defaults$scenario_id),
    facility_id = as.character(r$facility_id[[1]] %||% defaults$facility_id),
    retail_id = as.character(r$retail_id[[1]] %||% defaults$retail_id),
    trip_leg = as.character(r$trip_leg[[1]] %||% defaults$trip_leg),
    units_per_case_policy = as.character(r$units_per_case_policy[[1]] %||% defaults$units_per_case_policy),
    case_geometry_policy = as.character(r$case_geometry_policy[[1]] %||% defaults$case_geometry_policy),
    load_assignment_policy = as.character(r$load_assignment_policy[[1]] %||% defaults$load_assignment_policy),
    artifact_mode = as.character(r$artifact_mode[[1]] %||% defaults$artifact_mode),
    notes = as.character(r$notes[[1]] %||% defaults$notes)
  )
}
artifact_mode <- tolower(trimws(as.character(opt$artifact_mode %||% "full")))
if (!artifact_mode %in% c("full", "summary_only")) {
  stop("--artifact_mode must be one of: full, summary_only")
}
store_charge_stop_details_cfg <- isTRUE(cfg$simulation$store_charge_stop_details %||% TRUE)
memory_cfg <- cfg$simulation$memory_monitor %||% list()
mode_defaults <- if (identical(artifact_mode, "summary_only")) {
  list(write_tracks = FALSE, write_events = FALSE, write_charge_details = FALSE, write_run_bundle = FALSE, compress_tracks = FALSE)
} else {
  list(write_tracks = TRUE, write_events = TRUE, write_charge_details = store_charge_stop_details_cfg, write_run_bundle = TRUE, compress_tracks = TRUE)
}
write_tracks <- if (cli_has_flag("--write_tracks")) parse_bool_flag(opt$write_tracks, default = mode_defaults$write_tracks) else mode_defaults$write_tracks
write_events <- if (cli_has_flag("--write_events")) parse_bool_flag(opt$write_events, default = mode_defaults$write_events) else mode_defaults$write_events
write_charge_details <- if (cli_has_flag("--write_charge_details")) parse_bool_flag(opt$write_charge_details, default = mode_defaults$write_charge_details) else mode_defaults$write_charge_details
write_run_bundle_flag <- if (cli_has_flag("--write_run_bundle")) parse_bool_flag(opt$write_run_bundle, default = mode_defaults$write_run_bundle) else mode_defaults$write_run_bundle
compress_tracks <- if (cli_has_flag("--compress_tracks")) parse_bool_flag(opt$compress_tracks, default = mode_defaults$compress_tracks) else mode_defaults$compress_tracks
memory_limit_mb <- safe_memory_numeric(
  if (cli_has_flag("--memory_limit_mb")) opt$memory_limit_mb else memory_cfg$rss_limit_mb %||% memory_cfg$memory_limit_mb %||% NA_real_,
  default = NA_real_
)
memory_log_every_runs <- safe_posint(
  if (cli_has_flag("--memory_log_every_runs")) opt$memory_log_every_runs else memory_cfg$log_every_runs %||% 25L,
  default = 25L
)
gc_every_runs <- safe_posint(
  if (cli_has_flag("--gc_every_runs")) opt$gc_every_runs else memory_cfg$gc_every_runs %||% 25L,
  default = 25L
)
mc_draws_n <- as.integer(opt$n)
duration_hours_override <- suppressWarnings(as.numeric(opt$duration_hours))
if (!is.finite(duration_hours_override) || duration_hours_override <= 0) duration_hours_override <- NA_real_
duration_hours_arg <- if (is.finite(duration_hours_override)) duration_hours_override else NULL
routes_path <- if (nzchar(opt$routes)) {
  resolve_repo_path(opt$routes, kind = "file", must_work = TRUE)
} else {
  resolve_repo_path(as.character(cfg$routing$routes_geometry_path %||% file.path(data_path, "routes_facility_to_petco.csv")), kind = "file", must_work = TRUE)
}
routes <- read_route_geometries(routes_path)
od_cache <- data.frame()
od_path <- resolve_repo_path(as.character(cfg$routing$od_cache_path %||% file.path(data_path, "google_routes_od_cache.csv")), kind = "file", must_work = FALSE)
if (nzchar(od_path) && file.exists(od_path)) {
  od_cache <- read_od_cache(od_path)
}

stations <- data.frame()
plans <- data.frame()
if (tolower(opt$powertrain) == "bev") {
  stations_path <- if (nzchar(opt$stations)) {
    resolve_repo_path(opt$stations, kind = "file", must_work = TRUE)
  } else {
    resolve_repo_path(as.character(cfg$charging$stations_path %||% file.path(data_path, "ev_charging_stations_corridor.csv")), kind = "file", must_work = TRUE)
  }
  plans_path <- if (nzchar(opt$plans)) {
    resolve_repo_path(opt$plans, kind = "file", must_work = TRUE)
  } else {
    resolve_repo_path(as.character(cfg$charging$route_plans_path %||% file.path(data_path, "bev_route_plans.csv")), kind = "file", must_work = TRUE)
  }
  stations <- read_ev_stations(stations_path)
  plans <- read_bev_route_plans(plans_path)
}

build_facility_context <- function(facility_id) {
  r <- select_route_row(routes, facility_id = facility_id, route_rank = 1L)
  elevation_path <- if (nzchar(opt$elevation)) {
    resolve_repo_path(opt$elevation, kind = "file", must_work = FALSE)
  } else {
    resolve_repo_path(file.path(data_path, "route_elevation_profiles.csv"), kind = "file", must_work = FALSE)
  }
  elev <- load_elevation_profile(elevation_path, route_id = r$route_id[[1]])
  segments <- build_route_segments(r, elevation_profile = elev)
  planned_stops <- data.frame()
  charging_candidates <- data.frame()
  selected_plan_id <- NA_character_
  if (tolower(opt$powertrain) == "bev") {
    charging_candidates <- if (exists("prepare_charge_candidates_for_route", mode = "function")) {
      prepare_charge_candidates_for_route(
        stations_df = stations,
        route_segments = segments,
        max_detour_miles = as.numeric(cfg$charging$max_detour_miles %||% 10)
      )
    } else {
      data.frame()
    }
    sel <- tryCatch(
      select_valid_plan_for_route(plans, stations, as.character(r$route_id[[1]]), segments, cfg$tractors$bev_ecascadia$soc_policy),
      error = function(e) {
        warning(
          "No valid BEV route plan for route_id=", as.character(r$route_id[[1]]),
          "; proceeding without planned stops (propulsion fallback only). reason=", conditionMessage(e)
        )
        NULL
      }
    )
    if (!is.null(sel)) {
      planned_stops <- sel$projected
      selected_plan_id <- as.character(sel$one$route_plan_id[[1]] %||% NA_character_)
    }
  }
  list(
    facility_id = facility_id,
    route_row = r,
    segments = segments,
    planned_stops = planned_stops,
    charging_candidates = charging_candidates,
    selected_plan_id = selected_plan_id
  )
}

facility_contexts <- if (paired_origin_networks) {
  origin_labels <- if (length(origin_pair_arg$values) > 0) unique(origin_pair_arg$values) else c("dry_factory_set", "refrigerated_factory_set")
  required_labels <- c("dry_factory_set", "refrigerated_factory_set")
  if (!all(required_labels %in% origin_labels)) {
    stop("--paired_origin_networks must include both dry_factory_set and refrigerated_factory_set when enabled.")
  }
  list(
    dry_factory_set = build_facility_context(opt$facility_id_dry),
    refrigerated_factory_set = build_facility_context(opt$facility_id_refrigerated)
  )
} else {
  list(single = build_facility_context(opt$facility_id))
}

if (tolower(opt$powertrain) == "bev") {
  bad <- names(facility_contexts)[vapply(facility_contexts, function(ctx) !nzchar(as.character(ctx$selected_plan_id %||% "")), logical(1))]
  if (length(bad) > 0) {
    routes_missing <- vapply(facility_contexts[bad], function(ctx) as.character(ctx$route_row$route_id[[1]] %||% NA_character_), character(1))
    stop(
      "BEV plan coverage check failed. Missing feasible route plan for origin(s): ",
      paste(bad, collapse = ", "),
      " route_id(s): ",
      paste(routes_missing, collapse = ", "),
      ". Update data/derived/bev_route_plans.csv or route/station inputs."
    )
  }
}

artifact_manifest_df <- NULL
if (isTRUE(write_run_bundle_flag)) {
  artifact_paths_for_bundle <- c(
    routes_geometry = "data/derived/routes_facility_to_petco.csv",
    bev_route_plans = "data/derived/bev_route_plans.csv",
    ev_stations = "data/derived/ev_charging_stations_corridor.csv",
    od_cache = "data/derived/google_routes_od_cache.csv"
  )
  artifact_manifest_df <- artifact_manifest(artifact_paths_for_bundle)
}

memory_label <- sanitize_id(if (nzchar(as.character(opt$worker_label %||% ""))) opt$worker_label else paste0("pid_", Sys.getpid()))
memory_profile_out <- if (nzchar(as.character(opt$memory_profile_out %||% ""))) {
  as.character(opt$memory_profile_out)
} else {
  file.path(opt$bundle_root, paste0("memory_profile_", memory_label, ".csv"))
}
memory_summary_out <- if (nzchar(as.character(opt$memory_summary_out %||% ""))) {
  as.character(opt$memory_summary_out)
} else {
  file.path(opt$bundle_root, paste0("memory_summary_", memory_label, ".json"))
}
runtime_summary_out <- if (nzchar(as.character(opt$runtime_summary_out %||% ""))) {
  as.character(opt$runtime_summary_out)
} else if (grepl("\\.csv$", as.character(opt$summary_out), ignore.case = TRUE)) {
  sub("\\.csv$", "_runtime.csv", as.character(opt$summary_out), ignore.case = TRUE)
} else {
  paste0(as.character(opt$summary_out), "_runtime.csv")
}
if (file.exists(memory_profile_out)) unlink(memory_profile_out)
if (file.exists(memory_summary_out)) unlink(memory_summary_out)
if (nzchar(runtime_summary_out) && file.exists(runtime_summary_out)) unlink(runtime_summary_out)
memory_monitor <- init_memory_monitor(profile_path = memory_profile_out, rss_limit_mb = memory_limit_mb)
memory_batch_id <- paste(opt$scenario, tolower(opt$powertrain), memory_label, opt$seed, sep = "_")
record_mem <- function(label, run_index = NA_integer_, force_gc = FALSE) {
  rec <- record_memory_snapshot(memory_monitor, label = label, run_index = run_index, force_gc = force_gc, log_label = "memory")
  memory_monitor <<- rec$monitor
  invisible(rec$snapshot)
}
record_mem("batch_start", run_index = 0L, force_gc = TRUE)

runs_tmp_csv <- file.path(opt$bundle_root, "route_sim_mc_runs_tmp.csv")
runs_tmp_has_header <- FALSE
batch_size <- as.integer(opt$batch_size %||% 50L)
if (is.na(batch_size) || batch_size < 1L) batch_size <- 50L
row_batch <- vector("list", batch_size)
row_batch_n <- 0L
flush_row_batch <- function() {
  if (row_batch_n == 0L) return(invisible(NULL))
  batch_df <- data.table::rbindlist(row_batch[seq_len(row_batch_n)], fill = TRUE, use.names = TRUE)
  dir.create(dirname(runs_tmp_csv), recursive = TRUE, showWarnings = FALSE)
  data.table::fwrite(
    batch_df,
    runs_tmp_csv,
    append = runs_tmp_has_header,
    col.names = !runs_tmp_has_header
  )
  runs_tmp_has_header <<- TRUE
  row_batch <<- vector("list", batch_size)
  row_batch_n <<- 0L
  rm(batch_df)
  invisible(gc(verbose = FALSE))
}
push_row_batch <- function(row) {
  row_batch_n <<- row_batch_n + 1L
  row_batch[[row_batch_n]] <<- row
  if (row_batch_n >= batch_size) flush_row_batch()
  invisible(NULL)
}
write_progress <- function(i, status) {
  if (!nzchar(opt$progress_file)) return(invisible(NULL))
  p <- data.frame(
    worker_label = as.character(opt$worker_label %||% ""),
    i = as.integer(i),
    n = as.integer(opt$n),
    status = as.character(status),
    timestamp_utc = as.character(format(Sys.time(), tz = "UTC", usetz = TRUE)),
    stringsAsFactors = FALSE
  )
  dir.create(dirname(opt$progress_file), recursive = TRUE, showWarnings = FALSE)
  data.table::fwrite(
    p,
    opt$progress_file,
    append = file.exists(opt$progress_file),
    col.names = !file.exists(opt$progress_file)
  )
}

write_progress(0L, "STARTING")
batch_start_time <- Sys.time()
expected_pair_bundles <- 0L
pair_bundles_created <- 0L
traffic_modes <- if (paired_traffic_modes) {
  if (length(traffic_pair_arg$values) > 0) unique(traffic_pair_arg$values) else c("stochastic", "freeflow")
} else {
  traffic_mode_input
}
for (i in seq_len(as.integer(opt$n))) {
  s <- as.integer(opt$seed) + i - 1L
  exo <- sample_exogenous_draws(cfg, seed = s)
  pair_id_base <- paste0(opt$scenario, "_", tolower(opt$powertrain), "_seed_", s)

  exo_for_mode <- function(mode) {
    out <- exo
    if (identical(mode, "freeflow")) {
      out$traffic_multiplier <- 1.0
      out$queue_delay_minutes <- 0.0
    }
    out
  }

  run_one <- function(ctx, origin_network_label, traffic_mode_label) {
    exo_mode <- exo_for_mode(traffic_mode_label)
    state_retention_run <- if (isTRUE(write_tracks)) "full" else "first_last"
    retain_event_log_run <- isTRUE(write_events)
    retain_charge_details_run <- isTRUE(write_charge_details)
    resolved_origin_network <- as.character(origin_network_label %||% origin_network_single)
    resolved_product_type <- product_type_for_origin(resolved_origin_network)
    resolved_cold_chain_required <- if (length(reefer_state_arg$cold_chain_required) > 0 && !is.na(reefer_state_arg$cold_chain_required[[1]])) {
      isTRUE(reefer_state_arg$cold_chain_required[[1]])
    } else {
      isTRUE(cold_chain_required_from_product_type(resolved_product_type, default = TRUE))
    }
    resolved_reefer_state <- if (isTRUE(resolved_cold_chain_required)) "on" else "off"
    scenario_meta <- resolve_scenario_meta(
      scenario = opt$scenario,
      product_type = resolved_product_type,
      powertrain = tolower(opt$powertrain),
      origin_network = resolved_origin_network,
      traffic_mode = traffic_mode_label,
      trip_leg = tolower(opt$trip_leg)
    )
    pair_id <- if (paired_origin_networks && paired_traffic_modes) {
      paste0(pair_id_base, "_", as.character(traffic_mode_label))
    } else if (paired_traffic_modes) {
      pair_id_base
    } else if (!paired_origin_networks) {
      paste(
        opt$scenario,
        tolower(opt$powertrain),
        resolved_origin_network,
        resolved_product_type,
        resolved_reefer_state,
        "seed",
        s,
        sep = "_"
      )
    } else {
      pair_id_base
    }
    rid <- if (paired_origin_networks) {
      paste(opt$scenario, tolower(opt$powertrain), origin_network_label, traffic_mode_label, s, sep = "_")
    } else {
      paste(opt$scenario, tolower(opt$powertrain), resolved_origin_network, resolved_product_type, resolved_reefer_state, traffic_mode_label, s, sep = "_")
    }
    if (exists("configure_log", mode = "function")) {
      configure_log(
        run_id = rid,
        lane = as.character(opt$worker_label %||% Sys.getenv("COLDCHAIN_LANE", unset = "route_sim_mc")),
        seed = as.character(s),
        tag = "route_sim_mc"
      )
    }
    sim <- simulate_route_day(
      route_segments = ctx$segments,
      cfg = cfg,
      powertrain = tolower(opt$powertrain),
      scenario = opt$scenario,
      seed = s,
      trip_leg = tolower(opt$trip_leg),
      duration_hours = duration_hours_arg,
      planned_stops = ctx$planned_stops,
      charging_candidates = ctx$charging_candidates,
      od_cache = od_cache,
      exogenous_draws = exo_mode,
      product_type = resolved_product_type,
      cold_chain_required = resolved_cold_chain_required,
      load_assignment_policy = as.character(scenario_meta$load_assignment_policy %||% "full_truckload"),
      state_retention = state_retention_run,
      retain_event_log = retain_event_log_run,
      retain_charge_details = retain_charge_details_run
    )
    record_mem(paste0("run_post_sim:", rid), run_index = i)
    paths <- write_route_sim_outputs(
      sim = sim,
      run_id = rid,
      write_tracks = write_tracks,
      write_events = write_events,
      write_charge_details = write_charge_details
    )
    run_context <- list(
      run_id = rid,
      scenario_id = as.character(scenario_meta$scenario_id %||% opt$scenario),
      scenario = opt$scenario,
      product_type = resolved_product_type,
      cold_chain_required = resolved_cold_chain_required,
      reefer_state = resolved_reefer_state,
      origin_network = resolved_origin_network,
      traffic_mode = traffic_mode_label,
      facility_id = coalesce_scalar(scenario_meta$facility_id, ctx$facility_id),
      retail_id = coalesce_scalar(scenario_meta$retail_id, NA_character_),
      route_id = as.character(ctx$route_row$route_id[[1]]),
      route_plan_id = ctx$selected_plan_id,
      powertrain = tolower(opt$powertrain),
      trip_leg = as.character(scenario_meta$trip_leg %||% tolower(opt$trip_leg)),
      seed = s,
      mc_draws = mc_draws_n,
      pair_id = pair_id,
      units_per_case_policy = as.character(scenario_meta$units_per_case_policy %||% NA_character_),
      case_geometry_policy = as.character(scenario_meta$case_geometry_policy %||% NA_character_),
      load_assignment_policy = as.character(scenario_meta$load_assignment_policy %||% "full_truckload"),
      artifact_mode = as.character(scenario_meta$artifact_mode %||% artifact_mode),
      scenario_notes = as.character(scenario_meta$notes %||% NA_character_),
      traffic_multiplier = as.numeric(exo_mode$traffic_multiplier %||% NA_real_),
      queue_delay_minutes = safe_nonneg(exo_mode$queue_delay_minutes, default = 0)
    )
    bundle <- NULL
    if (isTRUE(write_run_bundle_flag)) {
      bundle <- write_run_bundle(
        sim = sim,
        context = run_context,
        cfg_resolved = cfg,
        artifact_manifest_df = artifact_manifest_df,
        tracks_path = if (isTRUE(write_tracks)) paths$track_path else NULL,
        bundle_root = opt$bundle_root,
        write_events = write_events,
        write_charge_details = write_charge_details,
        write_tracks_gz = compress_tracks
      )
    }
    record_mem(paste0("run_post_write:", rid), run_index = i)

    total_co2 <- if (nrow(sim$sim_state) > 0) suppressWarnings(as.numeric(tail(sim$sim_state$co2_kg_cum, 1))) else NA_real_
    route_completed <- isTRUE(sim$metadata$route_completed) || isTRUE(sim$metadata$completed)
    status_flags <- character()
    if (!route_completed) status_flags <- c(status_flags, "INCOMPLETE_ROUTE")
    if (isTRUE(sim$metadata$plan_soc_violation)) status_flags <- c(status_flags, "PLAN_SOC_VIOLATION")
    status <- if (length(status_flags) == 0L) "OK" else paste(unique(status_flags), collapse = "|")
    if (!is.finite(total_co2) || total_co2 < 0) {
      status <- if (identical(status, "OK")) "INVALID_CO2" else paste(status, "INVALID_CO2", sep = "|")
      total_co2 <- NA_real_
    }
    mc_row <- data.frame(
      run_id = rid,
      pair_id = pair_id,
      scenario_id = as.character(run_context$scenario_id %||% NA_character_),
      scenario = opt$scenario,
      powertrain = tolower(opt$powertrain),
      origin_network = resolved_origin_network,
      product_type = resolved_product_type,
      cold_chain_required = as.logical(resolved_cold_chain_required),
      reefer_state = resolved_reefer_state,
      traffic_mode = traffic_mode_label,
      facility_id = as.character(run_context$facility_id %||% NA_character_),
      retail_id = as.character(run_context$retail_id %||% NA_character_),
      trip_leg = as.character(run_context$trip_leg %||% NA_character_),
      units_per_case_policy = as.character(run_context$units_per_case_policy %||% NA_character_),
      case_geometry_policy = as.character(run_context$case_geometry_policy %||% NA_character_),
      load_assignment_policy = as.character(run_context$load_assignment_policy %||% NA_character_),
      artifact_mode = as.character(run_context$artifact_mode %||% NA_character_),
      payload_lb = as.numeric(exo_mode$payload_lb %||% NA_real_),
      ambient_f = as.numeric(exo_mode$ambient_f %||% NA_real_),
      traffic_multiplier = as.numeric(exo_mode$traffic_multiplier %||% NA_real_),
      queue_delay_minutes = safe_nonneg(exo_mode$queue_delay_minutes, default = 0),
      grid_kg_per_kwh = as.numeric(exo_mode$grid_kg_per_kwh %||% NA_real_),
      mpg = as.numeric(exo_mode$mpg %||% NA_real_),
      payload_max_lb_draw = as.numeric(exo_mode$payload_max_lb_draw %||% NA_real_),
      units_per_case_draw_dry = as.numeric(exo_mode$units_per_case_draw_dry %||% NA_real_),
      units_per_case_draw_refrigerated = as.numeric(exo_mode$units_per_case_draw_refrigerated %||% NA_real_),
      cases_per_pallet_draw_dry = as.numeric(exo_mode$cases_per_pallet_draw_dry %||% NA_real_),
      cases_per_pallet_draw_refrigerated = as.numeric(exo_mode$cases_per_pallet_draw_refrigerated %||% NA_real_),
      pallet_tare_lb_draw = as.numeric(exo_mode$pallet_tare_lb_draw %||% NA_real_),
      packing_efficiency_draw_refrigerated = as.numeric(exo_mode$packing_efficiency_draw_refrigerated %||% NA_real_),
      pack_pattern_index_refrigerated = as.integer(exo_mode$pack_pattern_index_refrigerated %||% NA_integer_),
      units_per_truck_capacity = as.numeric(sim$metadata$load$units_per_truck_capacity %||% NA_real_),
      cases_per_truck_capacity = as.numeric(sim$metadata$load$cases_per_truck_capacity %||% NA_real_),
      assigned_units = as.numeric(sim$metadata$load$assigned_units %||% NA_real_),
      assigned_cases = as.numeric(sim$metadata$load$assigned_cases %||% NA_real_),
      actual_units_loaded = as.numeric(sim$metadata$load$actual_units_loaded %||% NA_real_),
      load_fraction = as.numeric(sim$metadata$load$load_fraction %||% NA_real_),
      unused_capacity_units = as.numeric(sim$metadata$load$unused_capacity_units %||% NA_real_),
      load_unload_min = safe_nonneg(exo_mode$load_unload_min, default = 0),
      refuel_stop_min = safe_nonneg(exo_mode$refuel_stop_min, default = 0),
      connector_overhead_min = safe_nonneg(exo_mode$connector_overhead_min, default = 0),
      bundle_dir = as.character(bundle$bundle_dir %||% NA_character_),
      route_completed = as.logical(route_completed),
      status = status,
      co2_kg_total = total_co2,
      stringsAsFactors = FALSE
    )

    run_record <- if (!is.null(bundle$run_record)) {
      bundle$run_record
    } else {
      list(
        run_id = rid,
        pair_id = pair_id,
        scenario_id = as.character(run_context$scenario_id %||% NA_character_),
        scenario = as.character(opt$scenario),
        origin_network = resolved_origin_network,
        product_type = resolved_product_type,
        cold_chain_required = as.logical(resolved_cold_chain_required),
        reefer_state = resolved_reefer_state,
        traffic_mode = traffic_mode_label,
        facility_id = as.character(run_context$facility_id %||% NA_character_),
        retail_id = as.character(run_context$retail_id %||% NA_character_),
        trip_leg = as.character(run_context$trip_leg %||% NA_character_),
        units_per_case_policy = as.character(run_context$units_per_case_policy %||% NA_character_),
        case_geometry_policy = as.character(run_context$case_geometry_policy %||% NA_character_),
        load_assignment_policy = as.character(run_context$load_assignment_policy %||% NA_character_),
        artifact_mode = as.character(run_context$artifact_mode %||% NA_character_),
        route_id = as.character(ctx$route_row$route_id[[1]]),
        route_completed = as.logical(route_completed),
        status = as.character(status)
      )
    }
    summary_record <- if (!is.null(bundle$summary_record) && nrow(bundle$summary_record) > 0) {
      bundle$summary_record
    } else {
      run_summary_row(sim, run_context)
    }
    if (is.null(summary_record) || nrow(summary_record) == 0) {
      # Keep paired-origin bundle creation resilient when a run has no sim_state rows.
      summary_record <- data.frame(
        run_id = rid,
        pair_id = pair_id,
        scenario_id = as.character(run_context$scenario_id %||% opt$scenario),
        scenario = as.character(opt$scenario),
        powertrain = as.character(tolower(opt$powertrain)),
        traffic_mode = as.character(traffic_mode_label),
        product_type = as.character(resolved_product_type),
        origin_network = as.character(resolved_origin_network),
        cold_chain_required = as.logical(resolved_cold_chain_required),
        reefer_state = resolved_reefer_state,
        facility_id = as.character(run_context$facility_id %||% NA_character_),
        retail_id = as.character(run_context$retail_id %||% NA_character_),
        trip_leg = as.character(run_context$trip_leg %||% tolower(opt$trip_leg)),
        units_per_case_policy = as.character(run_context$units_per_case_policy %||% NA_character_),
        case_geometry_policy = as.character(run_context$case_geometry_policy %||% NA_character_),
        load_assignment_policy = as.character(run_context$load_assignment_policy %||% NA_character_),
        artifact_mode = as.character(run_context$artifact_mode %||% artifact_mode),
        route_id = as.character(ctx$route_row$route_id[[1]]),
        route_plan_id = as.character(ctx$selected_plan_id %||% NA_character_),
        leg = as.character(tolower(opt$trip_leg)),
        distance_miles = NA_real_,
        co2_kg_total = as.numeric(total_co2),
        energy_kwh_propulsion = NA_real_,
        energy_kwh_tru = NA_real_,
        energy_kwh_total = NA_real_,
        diesel_gal_propulsion = NA_real_,
        diesel_gal_tru = NA_real_,
        charge_stops = NA_real_,
        refuel_stops = NA_real_,
        kcal_per_truck = NA_real_,
        delivery_time_min = NA_real_,
        driver_driving_min = NA_real_,
        time_charging_min = NA_real_,
        time_refuel_min = NA_real_,
        time_traffic_delay_min = NA_real_,
        time_load_unload_min = NA_real_,
        driver_on_duty_min = NA_real_,
        driver_off_duty_min = NA_real_,
        trip_duration_total_h = NA_real_,
        route_completed = as.logical(route_completed),
        status = as.character(status),
        stringsAsFactors = FALSE
      )
    }
    if (!"route_completed" %in% names(summary_record)) summary_record$route_completed <- as.logical(route_completed)
    if (!"status" %in% names(summary_record)) summary_record$status <- as.character(status)
    if ("co2_kg_total" %in% names(summary_record) && grepl("INVALID_CO2", as.character(status), fixed = TRUE)) {
      summary_record$co2_kg_total[[1]] <- NA_real_
    }
    if (identical(tolower(as.character(run_context$powertrain %||% "")), "bev")) {
      ek <- if ("energy_kwh_propulsion" %in% names(summary_record)) suppressWarnings(as.numeric(summary_record$energy_kwh_propulsion[[1]])) else NA_real_
      if (!is.finite(ek) || ek <= 0) {
        if ("energy_kwh_propulsion" %in% names(summary_record)) summary_record$energy_kwh_propulsion[[1]] <- NA_real_
        if ("energy_kwh_tru" %in% names(summary_record)) summary_record$energy_kwh_tru[[1]] <- NA_real_
        if ("energy_kwh_total" %in% names(summary_record)) summary_record$energy_kwh_total[[1]] <- NA_real_
      }
    }
    if ("powertrain" %in% names(run_context) && identical(tolower(as.character(run_context$powertrain %||% "")), "bev")) {
      ek <- if ("energy_kwh_propulsion" %in% names(summary_record)) suppressWarnings(as.numeric(summary_record$energy_kwh_propulsion[[1]])) else NA_real_
      if (!is.finite(ek) || ek <= 0) {
        warning("BEV energy calculation returned zero. run_id=", as.character(rid))
      }
    }
    artifact_record <- if (!is.null(bundle$artifact_record)) {
      bundle$artifact_record
    } else {
      data.frame()
    }

    out <- list(
      mc_row = mc_row,
      status = as.character(status),
      run_record = run_record,
      summary_record = summary_record,
      artifact_record = artifact_record
    )
    rm(paths, bundle, sim, exo_mode, run_context, mc_row, run_record, summary_record, artifact_record)
    gc(verbose = FALSE)
    out
  }

  record_mem("run_start", run_index = i, force_gc = FALSE)
  iter_status <- "OK"
  iter_status_cap <- length(traffic_modes) * if (paired_origin_networks) 2L else 1L
  iter_statuses <- rep("OK", iter_status_cap)
  iter_status_n <- 0L
  push_iter_status <- function(x) {
    iter_status_n <<- iter_status_n + 1L
    iter_statuses[[iter_status_n]] <<- as.character(x %||% "OK")
    invisible(NULL)
  }
  for (tm in traffic_modes) {
    if (paired_origin_networks) {
      expected_pair_bundles <- expected_pair_bundles + 1L
      r1 <- run_one(facility_contexts$dry_factory_set, "dry_factory_set", tm)
      r2 <- run_one(facility_contexts$refrigerated_factory_set, "refrigerated_factory_set", tm)
      pair_dir <- materialize_paired_origin_bundle(
        bundle_root = opt$bundle_root,
        pair_id = as.character(r1$mc_row$pair_id[[1]]),
        routes_df = routes,
        member_records = list(
          list(run_record = r1$run_record, summary_record = r1$summary_record, mc_row = r1$mc_row, artifact_record = r1$artifact_record),
          list(run_record = r2$run_record, summary_record = r2$summary_record, mc_row = r2$mc_row, artifact_record = r2$artifact_record)
        )
      )
      if (is.null(pair_dir) || !nzchar(as.character(pair_dir)) || !dir.exists(pair_dir)) {
        stop("Paired-origin run requested but pair bundle was not created for pair_id=", as.character(r1$mc_row$pair_id[[1]]))
      }
      assert_pair_bundle_integrity(pair_dir, expected_traffic_mode = tm)
      pair_bundles_created <- pair_bundles_created + 1L
      cat("PAIR_BUNDLE_CREATED:", as.character(pair_dir), "members=2", "\n")
      push_row_batch(r1$mc_row)
      push_row_batch(r2$mc_row)
      push_iter_status(r1$status[[1]])
      push_iter_status(r2$status[[1]])
      rm(r1, r2, pair_dir)
    } else {
      r <- run_one(facility_contexts$single, origin_network_single, tm)
      push_row_batch(r$mc_row)
      push_iter_status(r$status[[1]] %||% "OK")
      rm(r)
    }
  }
  if (i %% gc_every_runs == 0L || i == as.integer(opt$n)) {
    gc(verbose = FALSE)
  }
  if (i %% memory_log_every_runs == 0L || i == as.integer(opt$n)) {
    cat("ITER", i, "/", as.integer(opt$n), "memory checkpoint", "\n")
    record_mem("batch_checkpoint", run_index = i, force_gc = TRUE)
  }
  record_mem("run_end", run_index = i, force_gc = FALSE)
  iter_statuses_active <- if (iter_status_n > 0L) iter_statuses[seq_len(iter_status_n)] else rep("OK", 1L)
  iter_status <- if (any(iter_statuses_active != "OK")) paste(unique(iter_statuses_active[iter_statuses_active != "OK"]), collapse = "|") else "OK"
  write_progress(i, iter_status)
  if (is.finite(opt$throttle_seconds) && as.numeric(opt$throttle_seconds) > 0) {
    Sys.sleep(as.numeric(opt$throttle_seconds))
  }
}

if (paired_origin_networks && pair_bundles_created < expected_pair_bundles) {
  stop(
    "Paired-origin requested but only ", pair_bundles_created,
    " pair bundles were created out of expected ", expected_pair_bundles, "."
  )
}

flush_row_batch()
if (!file.exists(runs_tmp_csv)) stop("No Monte Carlo runs were written to temporary CSV: ", runs_tmp_csv)
record_mem("pre_aggregate", run_index = as.integer(opt$n), force_gc = TRUE)
runs <- data.table::fread(runs_tmp_csv)
runs <- as.data.frame(runs)
sum_df <- summarize_route_sim_runs(runs)
batch_end_time <- Sys.time()
record_mem("post_aggregate", run_index = as.integer(opt$n), force_gc = FALSE)
memory_summary_df <- memory_summary_row(memory_monitor, batch_id = memory_batch_id, run_count = as.integer(opt$n))
wall_seconds <- as.numeric(difftime(batch_end_time, batch_start_time, units = "secs"))
runtime_summary_df <- if (nrow(sum_df) > 0) {
  keep_cols <- intersect(c("scenario", "powertrain", "traffic_mode", "product_type", "artifact_mode"), names(sum_df))
  sum_df[1, keep_cols, drop = FALSE]
} else {
  data.frame(stringsAsFactors = FALSE)
}
runtime_summary_df$worker_label <- as.character(opt$worker_label %||% "")
runtime_summary_df$batch_id <- as.character(memory_batch_id)
runtime_summary_df$run_count <- as.integer(opt$n)
runtime_summary_df$batch_wall_seconds <- wall_seconds
runtime_summary_df$avg_run_seconds <- ifelse(is.finite(wall_seconds) && as.integer(opt$n) > 0, wall_seconds / as.integer(opt$n), NA_real_)
if (nrow(memory_summary_df) > 0) {
  for (nm in names(memory_summary_df)) {
    if (nm %in% names(runtime_summary_df)) next
    runtime_summary_df[[nm]] <- memory_summary_df[[nm]][[1]]
  }
}
dir.create(dirname(opt$summary_out), recursive = TRUE, showWarnings = FALSE)
data.table::fwrite(sum_df, opt$summary_out)
if (nzchar(opt$runs_out)) {
  dir.create(dirname(opt$runs_out), recursive = TRUE, showWarnings = FALSE)
  data.table::fwrite(runs, opt$runs_out)
}
if (nzchar(runtime_summary_out)) {
  dir.create(dirname(runtime_summary_out), recursive = TRUE, showWarnings = FALSE)
  data.table::fwrite(runtime_summary_df, runtime_summary_out)
}
unlink(runs_tmp_csv)
rm(runs, sum_df, runtime_summary_df)
invisible(gc(verbose = FALSE))
record_mem("batch_end", run_index = as.integer(opt$n), force_gc = TRUE)
write_memory_summary(memory_summary_out, memory_monitor, batch_id = memory_batch_id, run_count = as.integer(opt$n))
write_progress(as.integer(opt$n), "DONE")
cat("Wrote", opt$summary_out, "\n")
if (nzchar(opt$runs_out)) cat("Wrote", opt$runs_out, "\n")
if (nzchar(runtime_summary_out)) cat("Wrote", runtime_summary_out, "\n")
cat("Wrote", memory_profile_out, "\n")
cat("Wrote", memory_summary_out, "\n")
