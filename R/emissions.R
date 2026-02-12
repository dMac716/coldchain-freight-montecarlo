#' Calculate Freight Emissions
#'
#' Deterministic model for calculating emissions from freight transport.
#' Compares dry freight versus refrigerated (cold-chain) freight.
#'
#' @param distance_km Numeric. Distance traveled in kilometers.
#' @param payload_tons Numeric. Payload weight in metric tons.
#' @param is_refrigerated Logical. Whether the freight is refrigerated.
#' @param ambient_temp_c Numeric. Ambient temperature in Celsius.
#' @param fuel_efficiency_l_per_100km Numeric. Base fuel efficiency in liters per 100km.
#' @param refrigeration_factor Numeric. Additional fuel consumption factor for refrigeration (default: 1.25).
#'
#' @return A list containing:
#'   \item{fuel_consumption_l}{Total fuel consumption in liters}
#'   \item{co2_emissions_kg}{CO2 emissions in kilograms}
#'   \item{total_cost_usd}{Estimated total cost in USD}
#'
#' @details
#' The model accounts for:
#' - Base fuel consumption based on distance and payload
#' - Additional refrigeration overhead for cold-chain transport
#' - Temperature-dependent efficiency adjustments
#' - CO2 emission factor of 2.68 kg CO2 per liter of diesel
#'
#' @export
#' @examples
#' # Dry freight
#' calculate_emissions(500, 20, FALSE, 20, 30)
#'
#' # Refrigerated freight
#' calculate_emissions(500, 20, TRUE, 25, 30)
calculate_emissions <- function(distance_km,
                                 payload_tons,
                                 is_refrigerated,
                                 ambient_temp_c,
                                 fuel_efficiency_l_per_100km,
                                 refrigeration_factor = 1.25) {
  
  # Validate inputs
  validate_inputs(list(
    distance_km = distance_km,
    payload_tons = payload_tons,
    ambient_temp_c = ambient_temp_c,
    fuel_efficiency_l_per_100km = fuel_efficiency_l_per_100km
  ))
  
  # Base fuel consumption
  base_fuel <- (distance_km / 100) * fuel_efficiency_l_per_100km
  
  # Payload adjustment (increase consumption by 2% per ton)
  payload_adjustment <- 1 + (0.02 * payload_tons)
  
  # Temperature adjustment for refrigeration
  temp_adjustment <- 1.0
  if (is_refrigerated) {
    # Higher ambient temps require more cooling
    temp_adjustment <- refrigeration_factor + (max(0, ambient_temp_c - 20) * 0.01)
  }
  
  # Total fuel consumption
  fuel_consumption_l <- base_fuel * payload_adjustment * temp_adjustment
  
  # CO2 emissions (2.68 kg CO2 per liter diesel)
  co2_emissions_kg <- fuel_consumption_l * 2.68
  
  # Estimated cost (fuel at $1.50/L, refrigeration overhead)
  fuel_cost <- fuel_consumption_l * 1.50
  refrigeration_cost <- if (is_refrigerated) distance_km * 0.15 else 0
  total_cost_usd <- fuel_cost + refrigeration_cost
  
  return(list(
    fuel_consumption_l = fuel_consumption_l,
    co2_emissions_kg = co2_emissions_kg,
    total_cost_usd = total_cost_usd,
    is_refrigerated = is_refrigerated
  ))
}
