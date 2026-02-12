# Example: Basic Emission Calculations
# This script demonstrates basic emission calculations for dry vs refrigerated freight

library(coldchainfreight)

# Example 1: Compare dry vs refrigerated freight for the same route
cat("=== Example 1: Route Comparison ===\n")

# Dry freight
dry <- calculate_emissions(
  distance_km = 500,
  payload_tons = 20,
  is_refrigerated = FALSE,
  ambient_temp_c = 20,
  fuel_efficiency_l_per_100km = 30
)

cat("\nDry Freight:\n")
cat(sprintf("  Fuel: %.2f L\n", dry$fuel_consumption_l))
cat(sprintf("  CO2: %.2f kg\n", dry$co2_emissions_kg))
cat(sprintf("  Cost: $%.2f\n", dry$total_cost_usd))

# Refrigerated freight
refrig <- calculate_emissions(
  distance_km = 500,
  payload_tons = 20,
  is_refrigerated = TRUE,
  ambient_temp_c = 20,
  fuel_efficiency_l_per_100km = 30
)

cat("\nRefrigerated Freight:\n")
cat(sprintf("  Fuel: %.2f L\n", refrig$fuel_consumption_l))
cat(sprintf("  CO2: %.2f kg\n", refrig$co2_emissions_kg))
cat(sprintf("  Cost: $%.2f\n", refrig$total_cost_usd))

# Calculate differences
cat("\nRefrigeration Impact:\n")
cat(sprintf("  Additional Fuel: %.2f L (%.1f%%)\n", 
            refrig$fuel_consumption_l - dry$fuel_consumption_l,
            100 * (refrig$fuel_consumption_l / dry$fuel_consumption_l - 1)))
cat(sprintf("  Additional CO2: %.2f kg (%.1f%%)\n",
            refrig$co2_emissions_kg - dry$co2_emissions_kg,
            100 * (refrig$co2_emissions_kg / dry$co2_emissions_kg - 1)))
cat(sprintf("  Additional Cost: $%.2f (%.1f%%)\n",
            refrig$total_cost_usd - dry$total_cost_usd,
            100 * (refrig$total_cost_usd / dry$total_cost_usd - 1)))

# Example 2: Temperature sensitivity
cat("\n\n=== Example 2: Temperature Sensitivity ===\n")

temps <- c(10, 20, 30, 40)
for (temp in temps) {
  result <- calculate_emissions(
    distance_km = 500,
    payload_tons = 20,
    is_refrigerated = TRUE,
    ambient_temp_c = temp,
    fuel_efficiency_l_per_100km = 30
  )
  cat(sprintf("Temp %2d°C: %.2f kg CO2, $%.2f\n", 
              temp, result$co2_emissions_kg, result$total_cost_usd))
}

# Example 3: Payload effects
cat("\n\n=== Example 3: Payload Effects ===\n")

payloads <- c(5, 10, 20, 30, 40)
for (payload in payloads) {
  result <- calculate_emissions(
    distance_km = 500,
    payload_tons = payload,
    is_refrigerated = FALSE,
    ambient_temp_c = 20,
    fuel_efficiency_l_per_100km = 30
  )
  cat(sprintf("Payload %2d tons: %.2f kg CO2\n", 
              payload, result$co2_emissions_kg))
}
