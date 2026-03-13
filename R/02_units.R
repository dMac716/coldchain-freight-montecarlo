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

resolve_fu_kcal <- function(functional_unit_df, fu_id = "FU_1000_KCAL", fallback = 1000) {
  if (is.null(functional_unit_df) || nrow(functional_unit_df) == 0) return(as.numeric(fallback))
  if (!all(c("fu_id", "fu_kcal") %in% names(functional_unit_df))) return(as.numeric(fallback))
  hit <- functional_unit_df[functional_unit_df$fu_id == fu_id, , drop = FALSE]
  if (nrow(hit) == 0) return(as.numeric(fallback))
  v <- suppressWarnings(as.numeric(hit$fu_kcal[[1]]))
  if (!is.finite(v) || v <= 0) return(as.numeric(fallback))
  v
}

mass_per_fu_kg_product_mode <- function(products_df, product_mode, FU_kcal = 1000) {
  if (is.null(products_df) || nrow(products_df) == 0) stop("products table is empty.")
  mode <- normalize_product_mode(product_mode)

  df <- products_df
  if ("product_mode" %in% names(df)) {
    df$product_mode <- toupper(trimws(as.character(df$product_mode)))
    hit <- df[df$product_mode == mode, , drop = FALSE]
  } else if ("preservation" %in% names(df)) {
    preservation <- toupper(trimws(as.character(df$preservation)))
    mapped <- ifelse(preservation == "REFRIGERATED", "REFRIGERATED", "DRY")
    hit <- df[mapped == mode, , drop = FALSE]
  } else {
    stop("products table requires product_mode or preservation column.")
  }

  if (nrow(hit) == 0) stop("No product row found for product_mode=", mode)
  hit <- hit[order(hit$product_id), , drop = FALSE][1, , drop = FALSE]

  kcal_per_kg <- suppressWarnings(as.numeric(hit$kcal_per_kg[[1]]))
  if (!is.finite(kcal_per_kg) || kcal_per_kg <= 0) stop("kcal_per_kg must be finite and > 0 for ", mode)

  pkg <- if ("packaging_mass_frac" %in% names(hit)) suppressWarnings(as.numeric(hit$packaging_mass_frac[[1]])) else 0
  if (!is.finite(pkg) || pkg < 0) pkg <- 0

  mass_per_fu_kg(FU_kcal = FU_kcal, kcal_per_kg = kcal_per_kg, pkg_kg_per_kg_product = pkg)
}

sha256_file <- function(path) {
  digest::digest(file = path, algo = "sha256", serialize = FALSE)
}

sha256_text <- function(text) {
  digest::digest(text, algo = "sha256", serialize = FALSE)
}
