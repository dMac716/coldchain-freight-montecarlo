kg_to_tons <- function(kg) {
  kg / 907.185
}

mass_per_fu_kg <- function(FU_kcal, kcal_per_kg, pkg_kg_per_kg_product) {
  product_kg <- FU_kcal / kcal_per_kg
  product_kg + product_kg * pkg_kg_per_kg_product
}

normalize_product_mode <- function(x) {
  y <- toupper(trimws(as.character(x)))
  if (length(y) != 1 || !nzchar(y)) stop("product_mode must be a non-empty scalar.")
  if (!y %in% c("DRY", "REFRIGERATED")) {
    stop("product_mode must be one of: DRY, REFRIGERATED.")
  }
  y
}

normalize_powertrain_config <- function(x) {
  y <- toupper(trimws(as.character(x)))
  if (length(y) != 1 || !nzchar(y)) stop("powertrain_config must be a non-empty scalar.")
  if (!y %in% c("DIESEL_TRU_DIESEL", "BEV_TRU_ELECTRIC")) {
    stop("powertrain_config must be one of: DIESEL_TRU_DIESEL, BEV_TRU_ELECTRIC.")
  }
  y
}

normalize_spatial_structure <- function(x) {
  y <- toupper(trimws(as.character(x)))
  if (length(y) != 1 || !nzchar(y)) stop("spatial_structure must be a non-empty scalar.")
  if (!y %in% c("CENTRALIZED", "REGIONALIZED", "SMOKE_LOCAL")) {
    stop("spatial_structure must be one of: CENTRALIZED, REGIONALIZED, SMOKE_LOCAL.")
  }
  y
}

sha256_file <- function(path) {
  digest::digest(file = path, algo = "sha256", serialize = FALSE)
}

sha256_text <- function(text) {
  digest::digest(text, algo = "sha256", serialize = FALSE)
}
