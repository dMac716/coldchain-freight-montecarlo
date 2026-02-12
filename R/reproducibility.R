#' Initialize Reproducibility Log
#'
#' Initializes a reproducibility log file with session information.
#'
#' @param log_file Character. Path to the log file.
#' @param overwrite Logical. Whether to overwrite existing log file.
#'
#' @return Path to the log file (invisibly).
#'
#' @export
#' @examples
#' log_path <- tempfile(fileext = ".json")
#' init_reproducibility_log(log_path)
init_reproducibility_log <- function(log_file = "reproducibility_log.json", 
                                     overwrite = FALSE) {
  
  if (file.exists(log_file) && !overwrite) {
    stop(sprintf("Log file '%s' already exists. Set overwrite=TRUE to replace.", log_file))
  }
  
  # Create log directory if needed
  log_dir <- dirname(log_file)
  if (!dir.exists(log_dir)) {
    dir.create(log_dir, recursive = TRUE)
  }
  
  # Gather session information
  session_info <- list(
    timestamp = as.character(Sys.time()),
    r_version = paste(R.version$major, R.version$minor, sep = "."),
    platform = R.version$platform,
    os = Sys.info()["sysname"],
    user = Sys.info()["user"],
    nodename = Sys.info()["nodename"],
    locale = Sys.getlocale(),
    working_directory = getwd(),
    package_version = utils::packageVersion("coldchainfreight"),
    random_seed = .Random.seed[1:6]  # First few elements for reference
  )
  
  # Get loaded package versions
  loaded_pkgs <- loadedNamespaces()
  pkg_versions <- sapply(loaded_pkgs, function(pkg) {
    as.character(utils::packageVersion(pkg))
  })
  
  session_info$loaded_packages <- as.list(pkg_versions)
  
  # Initialize log structure
  log_data <- list(
    log_version = "1.0",
    session_info = session_info,
    events = list()
  )
  
  # Write to file
  jsonlite::write_json(log_data, log_file, pretty = TRUE, auto_unbox = TRUE)
  
  # Store log file path in option
  options(coldchainfreight.log_file = log_file)
  
  message(sprintf("Reproducibility log initialized: %s", log_file))
  
  invisible(log_file)
}


#' Log Event
#'
#' Logs an event to the reproducibility log.
#'
#' @param event_type Character. Type of event to log.
#' @param event_data List. Data associated with the event.
#'
#' @return NULL (invisibly).
#'
#' @export
#' @examples
#' init_reproducibility_log(tempfile(fileext = ".json"))
#' log_event("test_event", list(value = 42))
log_event <- function(event_type, event_data = list()) {
  
  log_file <- getOption("coldchainfreight.log_file")
  
  if (is.null(log_file)) {
    warning("No log file initialized. Call init_reproducibility_log() first.")
    return(invisible(NULL))
  }
  
  if (!file.exists(log_file)) {
    warning(sprintf("Log file '%s' not found. Reinitializing.", log_file))
    init_reproducibility_log(log_file, overwrite = TRUE)
  }
  
  # Read existing log
  log_data <- jsonlite::read_json(log_file, simplifyVector = FALSE)
  
  # Create event entry
  event <- list(
    event_id = length(log_data$events) + 1,
    timestamp = as.character(Sys.time()),
    event_type = event_type,
    data = event_data
  )
  
  # Append event
  log_data$events <- c(log_data$events, list(event))
  
  # Write back to file
  jsonlite::write_json(log_data, log_file, pretty = TRUE, auto_unbox = TRUE)
  
  invisible(NULL)
}


#' Get Reproducibility Hash
#'
#' Generates a hash of the current reproducibility context.
#'
#' @return Character string containing MD5 hash of session info.
#'
#' @export
#' @examples
#' hash <- get_reproducibility_hash()
get_reproducibility_hash <- function() {
  
  # Gather key reproducibility information
  info <- list(
    r_version = paste(R.version$major, R.version$minor, sep = "."),
    platform = R.version$platform,
    pkg_version = as.character(utils::packageVersion("coldchainfreight")),
    seed = .Random.seed[1:6]
  )
  
  # Serialize and hash
  info_str <- jsonlite::toJSON(info, auto_unbox = TRUE)
  hash <- digest::digest(info_str, algo = "md5")
  
  return(hash)
}
