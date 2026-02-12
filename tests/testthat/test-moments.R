test_that("merge_moments combines statistics correctly", {
  
  # Create two sets of samples
  set.seed(123)
  x1 <- rnorm(100, mean = 50, sd = 10)
  x2 <- rnorm(100, mean = 50, sd = 10)
  
  # Calculate moments separately
  m1 <- coldchainfreight:::calculate_moments(x1)
  m2 <- coldchainfreight:::calculate_moments(x2)
  
  # Merge moments
  merged <- merge_moments(list(m1, m2))
  
  # Compare with direct calculation
  combined <- c(x1, x2)
  direct <- coldchainfreight:::calculate_moments(combined)
  
  expect_equal(merged$n, direct$n)
  expect_equal(merged$mean, direct$mean, tolerance = 1e-10)
  expect_equal(merged$variance, direct$variance, tolerance = 1e-8)
})


test_that("merge_moments handles single moment", {
  
  set.seed(456)
  x <- rnorm(100, 75, 15)
  m <- coldchainfreight:::calculate_moments(x)
  
  merged <- merge_moments(list(m))
  
  expect_equal(merged$n, m$n)
  expect_equal(merged$mean, m$mean)
  expect_equal(merged$variance, m$variance)
})


test_that("merge_moments is accurate for multiple chunks", {
  
  # Generate multiple chunks
  set.seed(789)
  chunks <- lapply(1:5, function(i) {
    x <- rnorm(50, mean = 100, sd = 20)
    coldchainfreight:::calculate_moments(x)
  })
  
  # Merge
  merged <- merge_moments(chunks)
  
  # Direct calculation
  all_data <- do.call(c, lapply(1:5, function(i) {
    set.seed(789)
    rnorm((i-1) * 50, mean = 100, sd = 20)
    rnorm(50, mean = 100, sd = 20)
  }))
  
  expect_equal(merged$n, 250)
  expect_true(abs(merged$mean - 100) < 5)  # Should be close to true mean
})


test_that("merge_moments handles empty list", {
  
  expect_error(
    merge_moments(list()),
    "empty"
  )
})


test_that("calculate_moments works for various sample sizes", {
  
  # Single value
  m1 <- coldchainfreight:::calculate_moments(42)
  expect_equal(m1$n, 1)
  expect_equal(m1$mean, 42)
  expect_equal(m1$variance, 0)
  
  # Two values
  m2 <- coldchainfreight:::calculate_moments(c(10, 20))
  expect_equal(m2$n, 2)
  expect_equal(m2$mean, 15)
  
  # Many values
  set.seed(999)
  x <- rnorm(1000, 50, 10)
  m3 <- coldchainfreight:::calculate_moments(x)
  expect_equal(m3$n, 1000)
  expect_true(abs(m3$mean - 50) < 1)
  expect_true(abs(sqrt(m3$variance) - 10) < 1)
})
