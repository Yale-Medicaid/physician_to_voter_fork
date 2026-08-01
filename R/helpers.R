#' Return an output path, or NULL if nothing was written
#'
#' @description Targets in this pipeline pass paths rather than data, so a function that
#' had nothing to write must hand back `NULL` rather than a path to a directory that does
#' not exist. Ending a writing function with this makes that automatic.
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
