# R/charger_event_logger.R
#
# Reusable helpers for stochastic charger availability event logging.
#
# Automatically sourced by any tool that uses:
#   list.files("R", pattern = "[.]R$", full.names = TRUE)
#
# Provides:
#   charger_event_columns()          canonical column order for charging_events.csv
#   configure_charger_log(run_id, out_dir)   set up per-run CSV output path
#   log_charge_stop_event(event_data)        append one event row (list or data.frame)
#   log_charger_phase(level, phase, msg, ...)  structured log line via log_event()
#
# Per-run event output written to:
#   <out_dir>/charging_events.csv
#
# Structured log lines follow the canonical format from R/log_helpers.R:
#   [ISO-8601-UTC] [charger] run_id="..." lane="..." seed="..." phase="..." status="..." msg="..."

# ---------------------------------------------------------------------------
# Column contract (matches schemas/charger_event_schema.json)
# ---------------------------------------------------------------------------

charger_event_columns <- function() {
  c(
    "run_id", "draw_index", "stop_index",
    "t_arrive_minutes",
    "charger_id", "station_id", "station_class",
    "compatible", "incompatibility_reason",
    "charger_state",
    "p_broken_effective", "p_occupied_effective",
    "wait_time_minutes", "charge_duration_minutes",
    "energy_delivered_kwh", "charger_power_kw_used",
    "pre_charge_soc", "post_charge_soc",
    "reefer_runtime_increment_minutes", "hos_delay_minutes",
    "detour_miles", "along_route_miles",
    "seed", "lane", "scenario_id", "powertrain"
  )
}


# ---------------------------------------------------------------------------
# Per-run event log state
# ---------------------------------------------------------------------------

.charger_log_env <- new.env(parent = emptyenv())
.charger_log_env$csv_path   <- ""
.charger_log_env$header_written <- FALSE


configure_charger_log <- function(run_id, out_dir = NULL) {
  if (is.null(out_dir) || !nzchar(out_dir)) {
    run_id_val <- if (nzchar(run_id)) run_id else
                    Sys.getenv("COLDCHAIN_RUN_ID", unset = "unknown")
    out_dir <- file.path("runs", run_id_val)
  }
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  .charger_log_env$csv_path        <- file.path(out_dir, "charging_events.csv")
  .charger_log_env$header_written  <- file.exists(.charger_log_env$csv_path)
  invisible(.charger_log_env$csv_path)
}


# ---------------------------------------------------------------------------
# Event row writer
# ---------------------------------------------------------------------------

log_charge_stop_event <- function(event_data) {
  csv_path <- .charger_log_env$csv_path
  if (!nzchar(csv_path)) {
    # Auto-configure from COLDCHAIN_RUN_ID if not yet set up
    run_id <- Sys.getenv("COLDCHAIN_RUN_ID", unset = "unknown")
    configure_charger_log(run_id)
    csv_path <- .charger_log_env$csv_path
  }
  if (!nzchar(csv_path)) return(invisible(NULL))

  cols  <- charger_event_columns()

  # Coerce to named list, fill missing columns with NA
  if (is.data.frame(event_data)) {
    row <- as.list(event_data[1, , drop = TRUE])
  } else {
    row <- as.list(event_data)
  }
  for (col in cols) {
    if (is.null(row[[col]])) row[[col]] <- NA
  }

  df <- as.data.frame(row[cols], stringsAsFactors = FALSE)

  write_header <- !isTRUE(.charger_log_env$header_written)
  utils::write.table(
    df,
    file      = csv_path,
    sep       = ",",
    row.names = FALSE,
    col.names = write_header,
    append    = !write_header,
    quote     = TRUE,
    na        = ""
  )
  .charger_log_env$header_written <- TRUE
  invisible(csv_path)
}


# ---------------------------------------------------------------------------
# Structured log helper (wraps log_event from R/log_helpers.R)
# ---------------------------------------------------------------------------

log_charger_phase <- function(level   = "INFO",
                               phase   = "charging",
                               msg     = "",
                               charger_id  = NULL,
                               station_id  = NULL,
                               state       = NULL,
                               stop_index  = NULL) {
  extra <- paste(
    c(
      if (!is.null(charger_id)) sprintf('charger_id="%s"', charger_id),
      if (!is.null(station_id)) sprintf('station_id="%s"', station_id),
      if (!is.null(state))      sprintf('charger_state="%s"', state),
      if (!is.null(stop_index)) sprintf('stop_index=%d', as.integer(stop_index))
    ),
    collapse = " "
  )
  full_msg <- if (nzchar(extra)) paste(msg, extra) else msg

  if (exists("log_event", mode = "function")) {
    log_event(level, phase, full_msg)
  } else {
    cat(sprintf('[%s] [charger] phase="%s" status="%s" msg="%s"\n',
                format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
                phase, level, full_msg))
  }
  invisible(NULL)
}
