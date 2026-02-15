#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
})

log_info <- function(...) message("[derive_ui] ", paste0(..., collapse = ""))

option_list <- list(
  make_option(c("--faf_csv"), type = "character", default = "", help = "Path to FAF OD CSV (optional; auto-discovered if omitted)."),
  make_option(c("--faf_meta_xlsx"), type = "character", default = "", help = "Path to FAF metadata workbook (optional; auto-discovered if omitted)."),
  make_option(c("--top_n"), type = "integer", default = 200L, help = "Top OD rows per scenario.")
)
opt <- parse_args(OptionParser(
  usage = "%prog [options]",
  description = "Generate static UI artifacts for Quarto/Leaflet map and scenario explorer from FAF/model outputs.",
  option_list = option_list
))

decode_xml_entities <- function(x) {
  x <- gsub("&amp;", "&", x, fixed = TRUE)
  x <- gsub("&lt;", "<", x, fixed = TRUE)
  x <- gsub("&gt;", ">", x, fixed = TRUE)
  x <- gsub("&quot;", "\"", x, fixed = TRUE)
  x <- gsub("&apos;", "'", x, fixed = TRUE)
  x
}

detect_existing <- function(candidates) {
  hits <- candidates[file.exists(candidates)]
  if (length(hits) == 0) return("")
  hits[[1]]
}

read_faf_zone_lookup <- function(meta_xlsx) {
  if (!nzchar(meta_xlsx) || !file.exists(meta_xlsx)) {
    return(data.frame(zone_id = character(), name = character(), stringsAsFactors = FALSE))
  }

  py <- paste(
    "import csv, re, sys, zipfile, xml.etree.ElementTree as ET",
    "path = sys.argv[1]",
    "ns = {'a':'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}",
    "with zipfile.ZipFile(path) as z:",
    "  ss_root = ET.fromstring(z.read('xl/sharedStrings.xml'))",
    "  shared = []",
    "  for si in ss_root.findall('a:si', ns):",
    "    txt = ''.join((t.text or '') for t in si.findall('.//a:t', ns))",
    "    shared.append(txt)",
    "  sheet = ET.fromstring(z.read('xl/worksheets/sheet3.xml'))",
    "  rows = []",
    "  for row in sheet.findall('.//a:sheetData/a:row', ns):",
    "    cols = {}",
    "    for c in row.findall('a:c', ns):",
    "      r = c.get('r', '')",
    "      col = re.sub(r'\\d+', '', r)",
    "      t = c.get('t')",
    "      v = c.find('a:v', ns)",
    "      if v is None:",
    "        continue",
    "      val = v.text or ''",
    "      if t == 's' and val.isdigit():",
    "        idx = int(val)",
    "        if 0 <= idx < len(shared):",
    "          val = shared[idx]",
    "      cols[col] = val",
    "    if not cols:",
    "      continue",
    "    rows.append((cols.get('A',''), cols.get('C','')))",
    "writer = csv.writer(sys.stdout)",
    "writer.writerow(['zone_id','name'])",
    "for z, n in rows[1:]:",
    "  z = str(z).strip()",
    "  if not z:",
    "    continue",
    "  writer.writerow([z, n.strip()])",
    sep = "\n"
  )

  py_file <- tempfile(fileext = ".py")
  writeLines(py, py_file)
  out <- tryCatch(
    system2("python3", c(py_file, meta_xlsx), stdout = TRUE, stderr = TRUE),
    error = function(e) character()
  )
  unlink(py_file)
  if (length(out) == 0) {
    return(data.frame(zone_id = character(), name = character(), stringsAsFactors = FALSE))
  }
  csv_text <- paste(out, collapse = "\n")
  if (!grepl("^zone_id,name", csv_text)) {
    return(data.frame(zone_id = character(), name = character(), stringsAsFactors = FALSE))
  }
  lookup <- utils::read.csv(text = csv_text, stringsAsFactors = FALSE)
  lookup$zone_id <- sprintf("%03d", as.integer(trimws(as.character(lookup$zone_id))))
  lookup$name <- decode_xml_entities(trimws(as.character(lookup$name)))
  lookup <- lookup[nzchar(lookup$zone_id), c("zone_id", "name"), drop = FALSE]
  lookup[!duplicated(lookup$zone_id), , drop = FALSE]
}

extract_state_abbr <- function(name) {
  if (is.na(name) || !nzchar(name)) return(NA_character_)
  m <- regexpr(",\\s*([A-Z]{2})(\\b|\\s|$)", name, perl = TRUE)
  if (m > 0) return(sub(".*,\\s*([A-Z]{2}).*", "\\1", regmatches(name, m)))
  m2 <- regexpr("Remainder of\\s+([A-Za-z ]+)$", name, perl = TRUE)
  if (m2 > 0) {
    state_name <- sub("Remainder of\\s+", "", regmatches(name, m2))
    idx <- match(trimws(state_name), state.name)
    if (!is.na(idx)) return(state.abb[[idx]])
  }
  if (name %in% state.name) {
    idx <- match(name, state.name)
    return(state.abb[[idx]])
  }
  if (grepl("\\bDistrict of Columbia\\b|\\bDC\\b", name, ignore.case = TRUE)) return("DC")
  NA_character_
}

state_centroid <- function(abbr) {
  if (is.na(abbr) || !nzchar(abbr)) return(c(NA_real_, NA_real_))
  if (abbr == "DC") return(c(38.9072, -77.0369))
  idx <- match(abbr, state.abb)
  if (is.na(idx)) return(c(NA_real_, NA_real_))
  c(state.center$y[[idx]], state.center$x[[idx]])
}

fallback_centroid <- function(zone_id) {
  id_num <- suppressWarnings(as.integer(gsub("[^0-9]", "", zone_id)))
  if (!is.finite(id_num)) id_num <- sum(utf8ToInt(zone_id))
  lat <- 24 + (id_num %% 250) / 10
  lon <- -124 + (id_num %% 580) / 10
  c(lat = max(min(lat, 49.5), 24), lon = max(min(lon, -66), -124))
}

distance_midpoint_miles <- function(dist_band) {
  m <- c(`1` = 25, `2` = 75, `3` = 175, `4` = 375, `5` = 625, `6` = 875, `7` = 1250, `8` = 1750, `9` = 2250)
  out <- m[as.character(dist_band)]
  as.numeric(ifelse(is.na(out), NA_real_, out))
}

build_scenario_summary <- function(out_path = "data/derived/scenario_summary.csv") {
  files <- list.files("outputs", pattern = "results_summary\\.csv$", recursive = TRUE, full.names = TRUE)
  if (length(files) == 0) {
    log_info("No outputs/*/results_summary.csv files found; skipping scenario_summary.csv generation.")
    return(invisible(FALSE))
  }

  rows <- list()
  required <- c("scenario_id", "variant_id", "powertrain", "trailer_type", "refrigeration_mode", "metric", "mean", "var", "p05", "p50", "p95", "source_path")
  for (f in files) {
    df <- tryCatch(utils::read.csv(f, stringsAsFactors = FALSE), error = function(e) data.frame())
    if (nrow(df) == 0 || !("metric" %in% names(df))) next
    run_meta_path <- file.path(dirname(f), "run_metadata.json")
    scenario_id <- basename(dirname(f))
    variant_id <- NA_character_
    powertrain <- NA_character_
    trailer_type <- NA_character_
    refrigeration_mode <- NA_character_

    if (file.exists(run_meta_path)) {
      meta <- tryCatch(jsonlite::fromJSON(run_meta_path), error = function(e) list())
      if (!is.null(meta$scenario_id) && nzchar(meta$scenario_id)) scenario_id <- meta$scenario_id
      if (!is.null(meta$variant_id) && nzchar(meta$variant_id)) variant_id <- meta$variant_id
    }
    if (identical(scenario_id, "aggregate")) scenario_id <- "AGGREGATE"

    if (is.na(variant_id) || !nzchar(variant_id)) {
      variant_id <- basename(dirname(f))
    }
    bits <- strsplit(variant_id, "_", fixed = TRUE)[[1]]
    if (length(bits) >= 3) {
      powertrain <- tolower(bits[[length(bits) - 1]])
      trailer_type <- tolower(bits[[length(bits)]])
      if (trailer_type == "dry") trailer_type <- "dry_van"
      if (trailer_type == "reefer") trailer_type <- "refrigerated"
      refrigeration_mode <- if (trailer_type == "refrigerated") "refrigerated" else "none"
    }

    df$scenario_id <- scenario_id
    df$variant_id <- variant_id
    df$powertrain <- powertrain
    df$trailer_type <- trailer_type
    df$refrigeration_mode <- refrigeration_mode
    df$source_path <- f
    for (nm in required) if (!(nm %in% names(df))) df[[nm]] <- NA
    df <- df[, required, drop = FALSE]
    rows[[length(rows) + 1]] <- df
  }
  if (length(rows) == 0) return(invisible(FALSE))
  out <- do.call(rbind, rows)
  dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(out, out_path, row.names = FALSE)
  log_info("Wrote ", out_path)
  invisible(TRUE)
}

default_faf_csv <- detect_existing(c(
  "data/cache/faf/FAF5.7.1_2018-2024.csv",
  "sources/FAF5.7.1/FAF5.7.1_2018-2024/FAF5.7.1_2018-2024.csv"
))
default_meta <- detect_existing(c(
  "sources/FAF5.7.1/FAF5.7.1_2018-2024/FAF5_metadata.xlsx"
))

faf_csv <- if (nzchar(opt$faf_csv)) opt$faf_csv else default_faf_csv
meta_xlsx <- if (nzchar(opt$faf_meta_xlsx)) opt$faf_meta_xlsx else default_meta

if (!nzchar(faf_csv) || !file.exists(faf_csv)) {
  log_info("FAF OD CSV not found. Looked for default paths and optional --faf_csv. No-op.")
  build_scenario_summary()
  quit(save = "no", status = 0)
}

hdr <- names(utils::read.csv(faf_csv, nrows = 0, stringsAsFactors = FALSE))
keep <- c("dms_orig", "dms_dest", "dms_mode", "sctg2", "dist_band", "tons_2024", "tmiles_2024")
if (!all(keep %in% hdr)) {
  stop("FAF CSV missing expected columns: ", paste(setdiff(keep, hdr), collapse = ", "))
}
col_classes <- rep("NULL", length(hdr))
names(col_classes) <- hdr
col_classes["dms_orig"] <- "character"
col_classes["dms_dest"] <- "character"
col_classes["dms_mode"] <- "character"
col_classes["sctg2"] <- "character"
col_classes["dist_band"] <- "integer"
col_classes["tons_2024"] <- "numeric"
col_classes["tmiles_2024"] <- "numeric"

log_info("Reading FAF OD CSV (selected columns only): ", faf_csv)
od <- utils::read.csv(faf_csv, stringsAsFactors = FALSE, colClasses = col_classes)

od$dms_orig <- sprintf("%03d", as.integer(od$dms_orig))
od$dms_dest <- sprintf("%03d", as.integer(od$dms_dest))
od$sctg2 <- sprintf("%02d", as.integer(od$sctg2))
od$tons_2024 <- suppressWarnings(as.numeric(od$tons_2024))
od$tmiles_2024 <- suppressWarnings(as.numeric(od$tmiles_2024))
od$distance_miles <- distance_midpoint_miles(od$dist_band)

food_groups <- sprintf("%02d", 1:8)
od <- subset(
  od,
  dms_mode == "1" &
    sctg2 %in% food_groups &
    is.finite(tons_2024) & tons_2024 > 0 &
    is.finite(distance_miles)
)
if (nrow(od) == 0) stop("No truck food OD rows after filters.")

summarize_flows <- function(df, scenario_id, top_n) {
  agg <- stats::aggregate(
    cbind(tons_2024, tmiles_2024, dist_weight = distance_miles * tons_2024) ~ dms_orig + dms_dest,
    data = df,
    FUN = sum,
    na.rm = TRUE
  )
  names(agg) <- c("origin_id", "dest_id", "tons", "ton_miles", "dist_weight")
  agg$distance_miles <- ifelse(agg$tons > 0, agg$dist_weight / agg$tons, NA_real_)
  agg$commodity_group <- "food_sctg_01_08"
  agg$scenario_id <- scenario_id
  agg <- agg[order(-agg$ton_miles, -agg$tons), c("origin_id", "dest_id", "tons", "ton_miles", "distance_miles", "commodity_group", "scenario_id"), drop = FALSE]
  head(agg, top_n)
}

top_n <- max(as.integer(opt$top_n), 10L)
flows_c <- summarize_flows(od, "CENTRALIZED", top_n)
flows_r <- summarize_flows(subset(od, dist_band <= 4), "REGIONALIZED", top_n)
flows <- rbind(flows_c, flows_r)

lookup <- read_faf_zone_lookup(meta_xlsx)
zones <- sort(unique(c(flows$origin_id, flows$dest_id)))
z <- data.frame(zone_id = zones, stringsAsFactors = FALSE)
z$name <- paste("FAF Zone", z$zone_id)
if (nrow(lookup) > 0) {
  idx <- match(z$zone_id, lookup$zone_id)
  hit <- !is.na(idx)
  z$name[hit] <- lookup$name[idx[hit]]
}

coords <- t(vapply(z$name, function(nm) {
  st <- extract_state_abbr(nm)
  sc <- state_centroid(st)
  if (all(is.finite(sc))) return(c(lat = sc[[1]], lon = sc[[2]]))
  c(lat = NA_real_, lon = NA_real_)
}, numeric(2)))
z$lat <- coords[, "lat"]
z$lon <- coords[, "lon"]
needs_fallback <- !is.finite(z$lat) | !is.finite(z$lon)
if (any(needs_fallback)) {
  fb <- t(vapply(z$zone_id[needs_fallback], fallback_centroid, numeric(2)))
  z$lat[needs_fallback] <- fb[, "lat"]
  z$lon[needs_fallback] <- fb[, "lon"]
}

dir.create("data/derived", recursive = TRUE, showWarnings = FALSE)
utils::write.csv(flows, "data/derived/faf_top_od_flows.csv", row.names = FALSE)
utils::write.csv(z[, c("zone_id", "name", "lat", "lon")], "data/derived/faf_zone_centroids.csv", row.names = FALSE)
log_info("Wrote data/derived/faf_top_od_flows.csv")
log_info("Wrote data/derived/faf_zone_centroids.csv")

build_scenario_summary()
