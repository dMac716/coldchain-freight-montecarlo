#!/usr/bin/env Rscript

message("bq_load_from_gcs.R is deprecated; forwarding to load_faf_from_gcs.R")
args <- commandArgs(trailingOnly = TRUE)
target <- file.path("tools", "faf_bq", "load_faf_from_gcs.R")
status <- system2("Rscript", c(target, args))
quit(save = "no", status = status)
