#' Return an output path, or NULL if nothing was written
#'
#' @description Targets pass paths, so a function with nothing to write must return `NULL`
#' rather than a path that does not exist.
#'
#' @param out_pth path the caller intended to write
#'
#' @return `out_pth` if it exists on disk, otherwise `NULL`
return_out_pth <- function(out_pth) {
  if (dir.exists(out_pth)) {
    return(out_pth)
  } else {
    return(NULL)
  }
}

#' Return an output path, having checked it is distinct in some column(s)
#'
#' @param out_pth path the caller intended to write
#' @param distinct_col one or more columns that should uniquely identify rows
#'
#' @return `out_pth` if it exists and is distinct, otherwise `NULL`. Aborts if the path
#'   exists but is not distinct.
return_out_pth_check_distinct <- function(out_pth, distinct_col) {
  if (!dir.exists(out_pth)) {
    return(NULL)
  }

  rlang::exec(assertthat::assert_that,
              !!!check_for_distinct_result(out_pth, distinct_col = distinct_col))

  out_pth
}

#' Check that a written dataset is distinct in some column(s)
#'
#' @description Returns a value suitable for splatting into `assertthat::assert_that()`:
#'
#' ```r
#' rlang::exec(assertthat::assert_that, !!!check_for_distinct_result(pth, "npi"))
#' ```
#'
#' @param out_pth path to a written arrow dataset
#' @param distinct_col one or more columns that should uniquely identify rows
#'
#' @return `TRUE`, or `list(FALSE, msg = ...)` carrying a formatted error
check_for_distinct_result <- function(out_pth, distinct_col) {
  n_rows <- arrow::open_dataset(out_pth) |>
    nrow()

  n_distinct <- arrow::open_dataset(out_pth) |>
    dplyr::select(dplyr::all_of(distinct_col)) |>
    dplyr::distinct() |>
    dplyr::collect() |>
    nrow()

  if (n_rows != n_distinct) {
    return(list(
      FALSE,
      msg = cli::format_error(c(
        "Result must be distinct in {.var {distinct_col}}",
        "x" = paste("Result has {.pkg {scales::comma(n_rows)}} rows but only",
                    "{.pkg {scales::comma(n_distinct)}} distinct combination{?s}"),
        ">" = "{.file {out_pth}}"
      ))
    ))
  }

  TRUE
}


#' Years the pipeline should build
#'
#' @description Defaults to the full panel. `P2V_YEARS` overrides it with a comma-separated
#' list, so a pilot run can be scoped without editing `_targets.R` -- and without the risk of
#' leaving it scoped and later running a "full" run that quietly is not.
#'
#' The `years` target must carry `tar_cue(mode = "always")` for this to work. Without it the
#' command is unchanged between runs, so targets reuses the cached value and the environment
#' variable is silently ignored. Verified both ways.
#'
#' @return integer vector of years
pipeline_years <- function() {
  v <- Sys.getenv("P2V_YEARS", "")
  if (!nzchar(v)) {
    return(2018:2025)
  }
  as.integer(trimws(strsplit(v, ",", fixed = TRUE)[[1]]))
}

#' States the pipeline should build
#'
#' @description Defaults to the 50 states plus DC. `P2V_STATES` overrides it, as
#' `pipeline_years()` does for years; the same `tar_cue(mode = "always")` requirement applies.
#'
#' @return character vector of two-letter abbreviations
pipeline_states <- function() {
  v <- Sys.getenv("P2V_STATES", "")
  if (!nzchar(v)) {
    return(sort(c(state.abb, "DC")))
  }
  toupper(trimws(strsplit(v, ",", fixed = TRUE)[[1]]))
}


#' Fetch a file over HTTP, once
#'
#' @description Idempotent. Downloads land on a `.part` name first, so an interrupted
#' transfer cannot leave a truncated file that the check would accept forever.
#'
#' @param url file to fetch
#' @param out_dir directory to download into
#' @param timeout seconds to allow; the default `options(timeout=)` of 60 is far too short
#'
#' @return path to the downloaded file
download_once <- function(url, out_dir, timeout = 3600) {
  dest <- file.path(out_dir, basename(url))

  if (file.exists(dest)) {
    return(dest)
  }

  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  old <- options(timeout = timeout)
  on.exit(options(old), add = TRUE)

  part <- paste0(dest, ".part")
  utils::download.file(url, destfile = part, mode = "wb", quiet = TRUE)

  assertthat::assert_that(
    file.exists(part) && file.size(part) > 0,
    msg = cli::format_error("Downloaded an empty file from {.url {url}}")
  )

  file.rename(part, dest)

  dest
}
