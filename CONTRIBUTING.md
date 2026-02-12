# Contributing to coldchainfreight

Thank you for considering contributing to coldchainfreight! This document provides guidelines for contributing to the project.

## Types of Contributions

### Running Simulations

1. Clone the repository
2. Install dependencies: `renv::restore()`
3. Modify parameters in `_targets.R` as needed
4. Run the pipeline: `targets::tar_make()`
5. Submit contribution artifacts (validated against JSON schema)

### Bug Reports

When reporting bugs, please include:
- Your R version and platform
- Package versions (`sessionInfo()`)
- Minimal reproducible example
- Expected vs actual behavior
- Error messages (if any)

### Feature Requests

- Describe the feature and its use case
- Explain why it would be valuable
- Consider implementation complexity

### Code Contributions

1. Fork the repository
2. Create a feature branch: `git checkout -b feature-name`
3. Make your changes
4. Add tests for new functionality
5. Ensure all tests pass: `devtools::test()`
6. Check the package: `devtools::check()`
7. Update documentation as needed
8. Commit with clear messages
9. Push to your fork
10. Submit a pull request

## Development Setup

```r
# Install development dependencies
install.packages(c("devtools", "testthat", "roxygen2", "renv"))

# Clone and setup
git clone https://github.com/dMac716/coldchain-freight-montecarlo.git
cd coldchain-freight-montecarlo

# In R
renv::restore()
devtools::load_all()
```

## Code Style

- Follow the tidyverse style guide
- Use roxygen2 for documentation
- Add examples to exported functions
- Keep functions focused and modular
- Write clear, descriptive variable names

## Testing

- All new functions must have tests
- Tests should cover edge cases
- Use `testthat::test_file()` for rapid iteration
- Aim for >80% code coverage

## Documentation

- Use roxygen2 comments for functions
- Include `@param`, `@return`, `@export`, `@examples`
- Update README.md for user-facing changes
- Add vignettes for complex workflows

## Pull Request Process

1. Update documentation and tests
2. Ensure `R CMD check` passes with no errors/warnings
3. Update DESCRIPTION if adding dependencies
4. Request review from maintainers
5. Address review feedback
6. Squash commits if requested

## Reproducibility Requirements

All contributions must:
- Work offline (no runtime API calls)
- Use explicit random seeds
- Include reproducibility logging
- Be deterministic and reproducible

## Questions?

Open an issue for discussion before starting major changes.

Thank you for contributing!
