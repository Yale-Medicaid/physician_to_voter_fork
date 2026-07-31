#' Resolve the latest L2 extract for one state-year
#'
#' @description L2 is partitioned `state=XX/year=YYYY/month=MM/day=DD`, where a single
#' `state=/year=` directory may hold several `month=/day=` subdirectories -- one per
#' extract date. Opening a dataset scoped at the `state=/year=` level would silently
#' union those distinct extracts together, so this resolves the single latest one and
#' returns only that leaf.
#'
#' Some state-years have no directory at all (currently 2024 MD, MS and NV). That is
#' absence of data, not an error, so it returns `NULL` and the branch drops out.
#'
#' @param state two-letter state abbreviation
#' @param year four-digit year
#' @param l2_path glue template for the L2 root, carrying `{state}` and `{year}`
#'   placeholders and stopping at the `year=` level
#'
#' @return path to the latest `month=MM/day=DD` leaf, or `NULL` if the state-year has
#'   no data
resolve_l2_extract <- function(state, year, l2_path) {
  stub <- glue::glue(l2_path, state = state, year = year)

  if (!dir.exists(stub)) {
    return(NULL)
  }

  # recurse = 1 reaches month=/day=; keep only the day= leaves
  leaves <- fs::dir_ls(stub, recurse = 1, type = "directory") |>
    as.character()
  leaves <- leaves[stringr::str_detect(basename(leaves), "^day=")]

  if (rlang::is_empty(leaves)) {
    return(NULL)
  }

  leaves[which.max(parse_l2_extract_date(leaves))]
}

#' Parse the extract date out of an L2 leaf path
#'
#' @param leaf one or more paths of the form `.../year=YYYY/month=MM/day=DD`
#'
#' @return a `Date` vector. Single-digit month/day components parse fine, so both
#'   `month=3` and `month=03` are accepted.
parse_l2_extract_date <- function(leaf) {
  as.Date(paste(stringr::str_extract(leaf, "(?<=year=)[0-9]+"),
                stringr::str_extract(leaf, "(?<=month=)[0-9]+"),
                stringr::str_extract(leaf, "(?<=day=)[0-9]+"),
                sep = "-"))
}

#' Pull the state out of an L2 path
#'
#' @description Note L2 nests `state=` *outside* `year=`, the reverse of the layout
#' this project writes its own derived data in. Position-based helpers borrowed from
#' elsewhere will therefore read L2 paths wrong; these parse by key instead.
#'
#' @param leaf one or more L2 paths
#'
#' @return character vector of two-letter state abbreviations
get_l2_state <- function(leaf) {
  stringr::str_extract(leaf, "(?<=state=)[A-Za-z]{2}")
}

#' Pull the year out of an L2 path
#'
#' @param leaf one or more L2 paths
#'
#' @return numeric vector of years
get_l2_year <- function(leaf) {
  as.numeric(stringr::str_extract(leaf, "(?<=year=)[0-9]{4}"))
}
