source(file.path("..", "..", "R", "11_lci_reports.R"), local = FALSE)

make_sheet <- function(start_row = 3, low_coverage = FALSE) {
  n <- 25
  mat <- matrix("", nrow = n, ncol = 9)
  mat[start_row, 1] <- "Flow costs"
  hdr <- c("Parameter", "Flow", "Inputs/Outputs", "Amount", "Price", "Units", "Overhead ratio", "Cost", "Units")
  mat[start_row + 1, 1:9] <- hdr
  mat[start_row + 2, 1:9] <- c("p1", "diesel", "Input", "10", "1.2", "kg", "0", if (low_coverage) "0" else "12", "EUR")
  mat[start_row + 3, 1:9] <- c("p2", "electricity", "Input", "5", "0.8", "kWh", "0", "0", "EUR")
  mat[start_row + 4, 1:9] <- c("p3", "labor", "Input", "1", "0.5", "h", "0", if (low_coverage) "0" else "1", "EUR")
  mat[start_row + 5, 1:3] <- ""
  mat[start_row + 6, 1:3] <- ""
  mat[start_row + 7, 1:3] <- ""
  mat[start_row + 8, 1] <- "Flow properties"
  as.data.frame(mat, stringsAsFactors = FALSE)
}

test_that("flow costs parser handles varying start rows and termination logic", {
  a <- lci_parse_flow_cost_block(make_sheet(start_row = 2), sheet_name = "SheetA")
  b <- lci_parse_flow_cost_block(make_sheet(start_row = 7), sheet_name = "SheetB")

  expect_true(isTRUE(a$summary$found[[1]]))
  expect_true(isTRUE(b$summary$found[[1]]))
  expect_equal(nrow(a$rows), 3)
  expect_equal(nrow(b$rows), 3)
  expect_true(all(a$rows$row_index < a$summary$block_end_row[[1]] + 1L))
  expect_true(all(b$rows$row_index < b$summary$block_end_row[[1]] + 1L))
  expect_true(is.finite(a$summary$cost_coverage[[1]]))
  expect_true(is.finite(b$summary$cost_coverage[[1]]))
})

test_that("low cost coverage warns and omits LCC totals", {
  parsed <- lci_parse_flow_cost_block(make_sheet(start_row = 4, low_coverage = TRUE), sheet_name = "LowCov")
  expect_warning(
    pol <- lci_apply_flow_cost_coverage_policy(parsed$summary, coverage_threshold = 0.25, warn_prefix = "sheet=LowCov"),
    regexp = "Flow cost coverage low"
  )
  expect_equal(pol$lcc_total_included[[1]], 0)
  expect_true(is.na(pol$cost_total_eur[[1]]))
  expect_true(is.na(pol$pos_cost_total_eur[[1]]))
})
