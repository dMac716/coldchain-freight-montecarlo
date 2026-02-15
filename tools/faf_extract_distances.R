#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
})

source_files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
for (f in source_files) source(f, local = FALSE)

weighted_quantile <- function(x, w, probs) {
  ord <- order(x)
  x <- x[ord]
  w <- w[ord]
  cw <- cumsum(w) / sum(w)
  vapply(probs, function(p) x[which(cw >= p)[1]], numeric(1))
}

dist_band_midpoint <- function(band) {
  band <- as.integer(band)
  mids <- c(
    `1` = 25, `2` = 75, `3` = 175, `4` = 375, `5` = 625,
    `6` = 875, `7` = 1250, `8` = 1750, `9` = 2250
  )
  out <- mids[as.character(band)]
  as.numeric(out)
}

option_list <- list(
  make_option(c("--zip"), type = "character", default = "sources/FAF5.7.1/FAF5.7.1_2018-2024.zip", help = "FAF zip path"),
  make_option(c("--out"), type = "character", default = "data/derived/faf_distance_distributions.csv", help = "Output CSV"),
  make_option(c("--meta"), type = "character", default = "data/derived/faf_distance_distributions.meta.json", help = "Output metadata JSON"),
  make_option(c("--sctg"), type = "character", default = "01,02,03,04,05,06,07,08", help = "Comma-separated SCTG2 groups for food"),
  make_option(c("--year_col"), type = "character", default = "tons_2024", help = "Weight column name")
)
opt <- parse_args(OptionParser(option_list = option_list))

if (!file.exists(opt$zip)) stop("FAF zip not found: ", opt$zip)
csv_name <- utils::unzip(opt$zip, list = TRUE)$Name
csv_name <- csv_name[grepl("\\.csv$", csv_name, ignore.case = TRUE)]
if (length(csv_name) == 0) stop("No CSV in zip: ", opt$zip)
csv_name <- csv_name[[1]]

header <- strsplit(readLines(unz(opt$zip, csv_name), n = 1), ",")[[1]]
header <- trimws(header)
needed <- c("dms_mode", "sctg2", "dist_band", opt$year_col)
missing <- setdiff(needed, header)
if (length(missing) > 0) stop("Missing required FAF columns: ", paste(missing, collapse = ", "))

col_classes <- rep("NULL", length(header))
names(col_classes) <- header
col_classes["dms_mode"] <- "character"
col_classes["sctg2"] <- "character"
col_classes["dist_band"] <- "integer"
col_classes[opt$year_col] <- "numeric"

faf <- utils::read.csv(
  unz(opt$zip, csv_name),
  colClasses = unname(col_classes),
  stringsAsFactors = FALSE
)
names(faf) <- c("dms_mode", "sctg2", "dist_band", "tons")
faf <- faf[is.finite(faf$tons) & faf$tons > 0, , drop = FALSE]

sctg_keep <- trimws(strsplit(opt$sctg, ",")[[1]])
faf <- subset(faf, dms_mode == "1" & sctg2 %in% sctg_keep)
faf$distance_miles <- dist_band_midpoint(faf$dist_band)
faf <- faf[is.finite(faf$distance_miles), , drop = FALSE]
if (nrow(faf) == 0) stop("No FAF rows after filters.")

all_q <- weighted_quantile(faf$distance_miles, faf$tons, probs = c(0.05, 0.5, 0.95))
all_mean <- sum(faf$distance_miles * faf$tons) / sum(faf$tons)

regional <- subset(faf, dist_band <= 4)
if (nrow(regional) == 0) regional <- faf
reg_q <- weighted_quantile(regional$distance_miles, regional$tons, probs = c(0.05, 0.5, 0.95))
reg_mean <- sum(regional$distance_miles * regional$tons) / sum(regional$tons)

out <- data.frame(
  distance_distribution_id = c("dist_centralized_food_truck_2024", "dist_regionalized_food_truck_2024", "dist_smoke_local"),
  scenario_id = c("CENTRALIZED", "REGIONALIZED", "SMOKE_LOCAL"),
  source_zip = c(basename(opt$zip), basename(opt$zip), "synthetic"),
  commodity_filter = c(
    paste0("sctg2 in [", paste(sctg_keep, collapse = ","), "]"),
    paste0("sctg2 in [", paste(sctg_keep, collapse = ","), "]"),
    "n/a"
  ),
  mode_filter = c("dms_mode==1", "dms_mode==1 and dist_band<=4", "n/a"),
  distance_model = c("triangular_fit", "triangular_fit", "fixed"),
  p05_miles = c(all_q[[1]], reg_q[[1]], 1200),
  p50_miles = c(all_q[[2]], reg_q[[2]], 1200),
  p95_miles = c(all_q[[3]], reg_q[[3]], 1200),
  mean_miles = c(all_mean, reg_mean, 1200),
  min_miles = c(min(faf$distance_miles), min(regional$distance_miles), 1200),
  max_miles = c(max(faf$distance_miles), max(regional$distance_miles), 1200),
  n_records = c(nrow(faf), nrow(regional), 1),
  status = c("OK", "OK", "SMOKE_READY"),
  source_id = c("faf5_7_1_2018_2024_zip", "faf5_7_1_2018_2024_zip", "scope_locked_proposal_2026"),
  notes = c(
    "Weighted by tons_2024 with FAF dist_band midpoint mapping.",
    "Regionalized subset constrained to dist_band<=4.",
    "Synthetic smoke distribution."
  ),
  stringsAsFactors = FALSE
)

dir.create(dirname(opt$out), recursive = TRUE, showWarnings = FALSE)
utils::write.csv(out, opt$out, row.names = FALSE)

meta <- list(
  generated_at_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  source_zip = basename(opt$zip),
  csv_entry = csv_name,
  source_id = "faf5_7_1_2018_2024_zip",
  input_hash = sha256_text(paste(basename(opt$zip), csv_name, collapse = "|")),
  sctg_filter = sctg_keep,
  mode_filter = "dms_mode==1",
  dist_band_midpoint_assumption = "1:25,2:75,3:175,4:375,5:625,6:875,7:1250,8:1750,9:2250"
)
writeLines(jsonlite::toJSON(meta, auto_unbox = TRUE, pretty = TRUE), opt$meta)
message("FAF distance extraction complete: ", opt$out)
