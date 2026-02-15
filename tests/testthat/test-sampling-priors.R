test_that("sampling_priors covers required model param ids", {
  priors <- utils::read.csv(file.path("..", "..", "data", "inputs_local", "sampling_priors.csv"), stringsAsFactors = FALSE)
  covered <- unique(priors$param_id)
  missing <- setdiff(required_model_param_ids(), covered)
  expect_true(length(missing) == 0, label = paste("Missing prior params:", paste(missing, collapse = ", ")))
})

test_that("sampling_priors parameterization is valid", {
  priors <- utils::read.csv(file.path("..", "..", "data", "inputs_local", "sampling_priors.csv"), stringsAsFactors = FALSE)
  expect_silent(validate_sampling_priors(priors))
})
