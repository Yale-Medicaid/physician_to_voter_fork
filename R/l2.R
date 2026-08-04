#' Resolve the latest L2 extract for one state-year
#'
#' @description Returns a single `month=/day=` leaf. Scoping a dataset at `state=/year=`
#' would silently union several extract dates together.
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
#' @description Parses by key, not position: L2 nests `state=` outside `year=`, the reverse
#' of this project's own output.
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

#' Build the output subdirectory for one L2 partition
#'
#' @description Flips `state=/year=` to `year=/state=`. The single place that flip happens.
#'
#' @param leaf an L2 leaf path
#'
#' @return a `year=YYYY/state=XX` fragment
build_l2_out_subdir <- function(leaf) {
  glue::glue("year={get_l2_year(leaf)}/state={get_l2_state(leaf)}")
}

#' Name of the L2 occupation column for a given year
#'
#' @description A pure rename between 2024 and 2025; the value set is unchanged.
#'
#' @param year four-digit year
#'
#' @return the occupation column name for that year
l2_occupation_col <- function(year) {
  if (year <= 2024) {
    "CommercialData_Occupation"
  } else {
    "ConsumerData_Occupation_of_Person"
  }
}

#' Physicians in a state-year with no strong in-state candidate
#'
#' @description Selects who the cross-border pass should try. A physician is exempted only
#' when Stage A found **exactly one** candidate at or above `min_name_sim`; zero or several
#' both mean retry. Requiring uniqueness rather than a high maximum is what closes the
#' common-name hole. Deliberately model-free -- using `match_prob` would be circular, since
#' `n` is only correct once a year's states are combined. See CLAUDE.md.
#'
#' @param physician_data path to the cleaned physician dataset
#' @param lsh_pairs paths to the Stage A candidate pair datasets
#' @param state,year the state-year being processed
#' @param min_name_sim similarity an in-state candidate must beat to buy an exemption. A
#'   compute/recall dial: at the LSH threshold of 0.7 only physicians with no candidate at
#'   all are retried, at 1.0 essentially everyone is.
#'
#' @return a data frame of physician rows still wanting a match, or `NULL` if none
unmatched_physicians <- function(physician_data, lsh_pairs, state, year,
                                 min_name_sim = 0.85) {
  phys <- arrow::open_dataset(unique(dirname(physician_data))) |>
    dplyr::filter(year == !!year, state == !!state) |>
    dplyr::collect()

  if (nrow(phys) == 0) {
    return(NULL)
  }

  strong <- if (rlang::is_empty(lsh_pairs)) {
    tibble::tibble(npi = phys$npi[0], n_strong = integer(0))
  } else {
    arrow::open_dataset(unique(dirname(dirname(lsh_pairs)))) |>
      # !! not {{ }}: the embrace would inject the symbol, which the data mask resolves
      # to the identically named hive column, making the filter match every row
      dplyr::filter(year == !!year, state == !!state) |>
      dplyr::filter(full_name_sim >= min_name_sim) |>
      dplyr::count(npi, name = "n_strong") |>
      dplyr::collect()
  }

  out <- phys |>
    dplyr::left_join(strong, by = dplyr::join_by(npi)) |>
    dplyr::filter(is.na(n_strong) | n_strong != 1) |>
    dplyr::select(-n_strong)

  if (nrow(out) == 0) {
    return(NULL)
  }

  out
}
