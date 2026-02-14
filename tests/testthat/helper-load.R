root_dir <- normalizePath(file.path("..", ".."), winslash = "/", mustWork = TRUE)
r_dir <- file.path(root_dir, "R")
source_files <- list.files(r_dir, pattern = "\\.R$", full.names = TRUE)
for (f in source_files) source(f, local = FALSE)
