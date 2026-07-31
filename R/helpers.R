#' Return an output path, or NULL if it was never written
#'
#' @description Targets in this pipeline pass paths rather than data, so a function that
#' had nothing to write must hand back `NULL` rather than a path to a directory that does
#' not exist. Wrapping the return in this makes that automatic.
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

#' Check that a written dataset is distinct in some column
#'
#' @description Returns a value suitable for splatting into `assertthat::assert_that()`:
#'
#' ```r
#' rlang::exec(assertthat::assert_that, !!!check_for_distinct_result(pth, "npi"))
#' ```
#'
#' @param out_pth path to a written arrow dataset
#' @param distinct_col column that should uniquely identify rows
#'
#' @return `TRUE`, or `list(FALSE, msg = ...)` carrying a formatted error
check_for_distinct_result <- function(out_pth, distinct_col) {
  n_rows <- arrow::open_dataset(out_pth) |>
    nrow()

  n_distinct <- arrow::open_dataset(out_pth) |>
    dplyr::distinct(!!rlang::sym(distinct_col)) |>
    dplyr::collect() |>
    nrow()

  if (n_rows != n_distinct) {
    return(list(
      FALSE,
      msg = cli::format_error(c(
        "Result must be distinct in {.var {distinct_col}}",
        "x" = "Result has {.pkg {scales::comma(n_rows)}} rows but only {.pkg {scales::comma(n_distinct)}} distinct {.var {distinct_col}}s",
        ">" = "{.file {out_pth}}"
      ))
    ))
  }

  TRUE
}

#' Write a dataset and hand back its path
#'
#' @description The write half of the path-passing convention: clear any previous output,
#' write, and return the path so the calling target (declared `format = "file"`) tracks
#' the directory. `NULL` input passes straight through, which is what lets an empty
#' state-year branch stay empty.
#'
#' @param x a data frame or arrow object to write, or `NULL`
#' @param out_pth destination directory
#' @param ... passed to `arrow::write_dataset()`, e.g. `partitioning`
#'
#' @return `out_pth`, or `NULL` if `x` was `NULL`
write_and_return <- function(x, out_pth, ...) {
  if (rlang::is_empty(x)) {
    return(NULL)
  }

  unlink(out_pth, recursive = TRUE)
  dir.create(dirname(out_pth), recursive = TRUE, showWarnings = FALSE)

  arrow::write_dataset(x, out_pth, ...)

  return_out_pth(out_pth)
}
