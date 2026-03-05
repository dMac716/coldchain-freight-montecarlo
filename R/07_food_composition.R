# Food composition and functional-unit calculations (1,000 kcal basis).

normalize_token <- function(x) {
  gsub("[^a-z0-9]+", "", tolower(trimws(as.character(x %||% ""))))
}

dirichlet_draw <- function(alpha) {
  a <- as.numeric(alpha)
  a[!is.finite(a) | a <= 0] <- 1
  g <- stats::rgamma(length(a), shape = a, rate = 1)
  s <- sum(g)
  if (!is.finite(s) || s <= 0) return(rep(1 / length(a), length(a)))
  g / s
}

read_food_inputs <- function(base_dir = "data") {
  ing_path <- file.path(base_dir, "ingredients.csv")
  prod_path <- file.path(base_dir, "food_products.csv")
  lci_path <- file.path(base_dir, "lci_factors.csv")
  basket_yaml <- file.path(base_dir, "inputs", "product_ingredients.yaml")
  mapping_csv <- file.path(base_dir, "inputs", "ingredient_lci_mapping.csv")
  if (!file.exists(ing_path) || !file.exists(prod_path) || !file.exists(lci_path)) return(NULL)
  if (!file.exists(basket_yaml) || !file.exists(mapping_csv)) return(NULL)
  if (!requireNamespace("yaml", quietly = TRUE)) return(NULL)
  list(
    ingredients = utils::read.csv(ing_path, stringsAsFactors = FALSE),
    products = utils::read.csv(prod_path, stringsAsFactors = FALSE),
    lci_factors = utils::read.csv(lci_path, stringsAsFactors = FALSE),
    baskets = yaml::read_yaml(basket_yaml)$products,
    mapping = utils::read.csv(mapping_csv, stringsAsFactors = FALSE)
  )
}

lookup_product_label_profile <- function(product_type, food_inputs = NULL) {
  fi <- food_inputs %||% read_food_inputs("data")
  if (is.null(fi)) return(NULL)
  p <- tolower(as.character(product_type %||% ""))
  d <- fi$products[tolower(fi$products$product_type) == p, , drop = FALSE]
  if (nrow(d) == 0) return(NULL)
  list(
    kcal_per_kg_product = suppressWarnings(as.numeric(d$kcal_per_kg_label[[1]])),
    protein_g_per_kg_product = suppressWarnings(as.numeric(d$protein_g_per_kg_label[[1]])),
    kgco2_per_kg_product = NA_real_,
    ingredient_rows = data.frame()
  )
}

build_ingredient_share_draw <- function(product_type, fi, seed = 123, top_n = 5L, top_mass = 0.80, micro_mass = 0.02) {
  p <- tolower(as.character(product_type %||% ""))
  basket <- fi$baskets[[p]]
  if (is.null(basket) || is.null(basket$ingredients)) return(data.frame())
  ing <- as.character(unlist(basket$ingredients))
  map <- fi$mapping
  map$ingredient_raw_norm <- normalize_token(map$ingredient_raw)
  map$lci_key <- as.character(map$lci_key)
  map$is_micro_additive <- tolower(as.character(map$is_micro_additive %||% "false")) %in% c("true", "1", "yes", "y")
  d <- data.frame(
    ingredient_raw = ing,
    ingredient_raw_norm = normalize_token(ing),
    stringsAsFactors = FALSE
  )
  d <- merge(d, map[, c("ingredient_raw_norm", "lci_key", "confidence", "is_micro_additive"), drop = FALSE], by = "ingredient_raw_norm", all.x = TRUE)
  d$lci_key[!nzchar(d$lci_key)] <- "micro_additive"
  d$is_micro_additive[is.na(d$is_micro_additive)] <- FALSE
  d$order_rank <- match(d$ingredient_raw_norm, normalize_token(ing))
  d <- d[order(d$order_rank), , drop = FALSE]

  set.seed(as.integer(seed))
  n <- nrow(d)
  if (n == 0) return(d)
  top_n <- max(1L, min(as.integer(top_n), n))
  top_idx <- seq_len(top_n)
  rem_idx <- setdiff(seq_len(n), top_idx)
  micro_idx <- which(d$is_micro_additive)
  macro_idx <- setdiff(seq_len(n), micro_idx)

  shares <- rep(0, n)
  if (length(micro_idx) > 0) {
    shares[micro_idx] <- micro_mass / length(micro_idx)
  }
  remaining_mass <- 1 - sum(shares)
  remaining_mass <- max(0, remaining_mass)
  top_mass_eff <- min(top_mass, remaining_mass)
  rem_mass_eff <- max(0, remaining_mass - top_mass_eff)

  top_macro <- intersect(top_idx, macro_idx)
  rem_macro <- intersect(rem_idx, macro_idx)
  if (length(top_macro) > 0) {
    shares[top_macro] <- shares[top_macro] + top_mass_eff * dirichlet_draw(rep(2, length(top_macro)))
  } else if (length(rem_macro) > 0) {
    shares[rem_macro] <- shares[rem_macro] + top_mass_eff * dirichlet_draw(rep(1, length(rem_macro)))
  }
  if (length(rem_macro) > 0 && rem_mass_eff > 0) {
    shares[rem_macro] <- shares[rem_macro] + rem_mass_eff * dirichlet_draw(rep(1, length(rem_macro)))
  } else if (length(top_macro) > 0 && rem_mass_eff > 0) {
    shares[top_macro] <- shares[top_macro] + rem_mass_eff * dirichlet_draw(rep(1, length(top_macro)))
  }
  if (sum(shares) > 0) shares <- shares / sum(shares)
  d$mass_fraction <- shares
  d
}

compute_food_profile <- function(product_type, food_inputs = NULL, seed = 123) {
  fi <- food_inputs %||% read_food_inputs("data")
  if (is.null(fi)) return(NULL)

  d <- build_ingredient_share_draw(product_type, fi, seed = seed)
  if (nrow(d) == 0) return(NULL)

  ing <- fi$ingredients
  ing$ingredient <- normalize_token(ing$ingredient)
  ing$kcal_per_kg <- suppressWarnings(as.numeric(ing$kcal_per_kg))
  ing$protein_g_per_kg <- suppressWarnings(as.numeric(ing$protein_g_per_kg))
  ing$lci_factor_id <- as.character(ing$lci_factor_id)
  lci <- fi$lci_factors
  lci$factor_id <- as.character(lci$factor_id)
  lci$kgco2_per_kg <- suppressWarnings(as.numeric(lci$kgco2_per_kg))

  d$lci_key_norm <- normalize_token(d$lci_key)
  d <- merge(d, ing[, c("ingredient", "kcal_per_kg", "protein_g_per_kg", "lci_factor_id"), drop = FALSE], by.x = "lci_key_norm", by.y = "ingredient", all.x = TRUE)
  d <- merge(d, lci[, c("factor_id", "kgco2_per_kg"), drop = FALSE], by.x = "lci_key", by.y = "factor_id", all.x = TRUE)
  d$kgco2_per_kg[!is.finite(d$kgco2_per_kg)] <- 0

  # Use label energy/protein as fallback anchors.
  label <- lookup_product_label_profile(product_type, fi)
  fallback_kcal <- as.numeric(label$kcal_per_kg_product %||% NA_real_)
  fallback_protein <- as.numeric(label$protein_g_per_kg_product %||% NA_real_)
  d$kcal_per_kg[!is.finite(d$kcal_per_kg)] <- fallback_kcal
  d$protein_g_per_kg[!is.finite(d$protein_g_per_kg)] <- fallback_protein

  kcal_density <- sum(d$mass_fraction * d$kcal_per_kg, na.rm = TRUE)
  protein_density <- sum(d$mass_fraction * d$protein_g_per_kg, na.rm = TRUE)
  lci_density <- sum(d$mass_fraction * d$kgco2_per_kg, na.rm = TRUE)
  if (!is.finite(kcal_density) || kcal_density <= 0) kcal_density <- fallback_kcal
  if (!is.finite(protein_density) || protein_density <= 0) protein_density <- fallback_protein

  list(
    kcal_per_kg_product = as.numeric(kcal_density),
    protein_g_per_kg_product = as.numeric(protein_density),
    kgco2_per_kg_product = as.numeric(lci_density),
    ingredient_rows = d
  )
}

resolve_food_profile <- function(product_type, food_inputs = NULL, seed = 123) {
  prof <- compute_food_profile(product_type, food_inputs = food_inputs, seed = seed)
  if (!is.null(prof) && is.finite(prof$kcal_per_kg_product) && prof$kcal_per_kg_product > 0) return(prof)
  lookup_product_label_profile(product_type, food_inputs = food_inputs)
}

mass_required_for_fu_kg <- function(product_type, fu_kcal = 1000, food_inputs = NULL, seed = 123) {
  prof <- resolve_food_profile(product_type, food_inputs = food_inputs, seed = seed)
  if (is.null(prof) || !is.finite(prof$kcal_per_kg_product) || prof$kcal_per_kg_product <= 0) return(NA_real_)
  as.numeric(fu_kcal) / as.numeric(prof$kcal_per_kg_product)
}
