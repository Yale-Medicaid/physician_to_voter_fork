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

#' Build the output subdirectory for one L2 partition
#'
#' @description Flips the partition order. L2 arrives as `state=XX/year=YYYY`; everything
#' this project writes is `year=YYYY/state=XX`, matching the house convention. Doing the
#' flip in one named place keeps it from being silently re-derived (or reversed) at each
#' call site.
#'
#' @param leaf an L2 leaf path
#'
#' @return a `year=YYYY/state=XX` fragment
build_l2_out_subdir <- function(leaf) {
  glue::glue("year={get_l2_year(leaf)}/state={get_l2_state(leaf)}")
}

#' Name of the L2 occupation column for a given year
#'
#' @description L2 renamed its commercial fields to consumer ones between 2024 and 2025.
#' Only occupation has been verified in detail, and the *values* are unchanged across the
#' cutover, so this is a pure column rename with no value mapping.
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
#' @description Selects who the cross-border pass should try. "Unmatched" is defined
#' without reference to the model: a physician qualifies if their best in-state candidate
#' falls below `min_name_sim`, or if Stage A found them no candidate at all.
#'
#' Deliberately model-free. Defining it by RF probability would be circular, since `n` --
#' and therefore the prediction -- is only correct after a year's states are combined,
#' which happens downstream of this step.
#'
#' @param physician_data path to the cleaned physician dataset
#' @param lsh_pairs paths to the Stage A candidate pair datasets
#' @param state,year the state-year being processed
#' @param min_name_sim name-similarity an in-state candidate must beat for the physician to
#'   be considered already matched and skipped. Defaults to 0.85: only a *strong* in-state
#'   name match buys an exemption, because excluding someone on a mediocre in-state hit is
#'   the one error here that cannot be recovered downstream. Over-including is cheap by
#'   comparison -- an extra candidate pair costs compute, and the RF ranks it away.
#'
#'   This is really a compute/recall dial. At 0.7 (the LSH threshold) only physicians with
#'   no in-state candidate at all are retried; at 1.0 essentially everyone is, which is the
#'   same as always running the cross-border pass and skipping this selection entirely.
#'
#'   Note the limit of a similarity-only rule: a common name can yield many in-state
#'   candidates all scoring 0.99, none of them the right person, and this rule will still
#'   grant the exemption. Name similarity is not match quality -- that is what the RF is
#'   for, and it cannot be used here without circularity.
#'
#' @return a data frame of physician rows still wanting a match, or `NULL` if none
unmatched_physicians <- function(physician_data, lsh_pairs, state, year,
                                 min_name_sim = 0.85) {
  phys <- arrow::open_dataset(physician_data) |>
    dplyr::filter(tolower(provider_business_mailing_address_state_name) == tolower(state)) |>
    dplyr::collect()

  if (nrow(phys) == 0) {
    return(NULL)
  }

  # Stage A may have produced nothing for this state-year at all
  best <- if (rlang::is_empty(lsh_pairs)) {
    tibble::tibble(npi = phys$npi[0], best_sim = numeric(0))
  } else {
    arrow::open_dataset(unique(dirname(dirname(lsh_pairs)))) |>
      # {{ }} injects the argument's value, disambiguating it from the identically
      # named hive partition columns
      dplyr::filter(year == {{year}}, state == {{state}}) |>
      dplyr::group_by(npi) |>
      dplyr::summarize(best_sim = max(full_name_sim, na.rm = TRUE), .groups = "drop") |>
      dplyr::collect()
  }

  out <- phys |>
    dplyr::left_join(best, by = dplyr::join_by(npi)) |>
    # NA best_sim means Stage A found no candidate at all -- also unmatched
    dplyr::filter(is.na(best_sim) | best_sim < min_name_sim) |>
    dplyr::select(-best_sim)

  if (nrow(out) == 0) {
    return(NULL)
  }

  out
}
