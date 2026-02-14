kg_to_tons <- function(kg) {
  kg / 907.185
}

mass_per_fu_kg <- function(FU_kcal, kcal_per_kg, pkg_kg_per_kg_product) {
  product_kg <- FU_kcal / kcal_per_kg
  product_kg + product_kg * pkg_kg_per_kg_product
}

sha256_file <- function(path) {
  digest::digest(file = path, algo = "sha256", serialize = FALSE)
}

sha256_text <- function(text) {
  digest::digest(text, algo = "sha256", serialize = FALSE)
}
