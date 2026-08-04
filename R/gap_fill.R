#' Classify every empty physician-year in the panel
#'
#' @description Four gates decide whether a gap can be filled -- `has_anchor`,
#' `unambiguous`, `state_stable`, `near` -- and `NA` fails all of them. `fill_tier` then
#' records why the year was empty: 1 = no L2 partition existed, 2 = L2 existed and the
#' physician was not matched, 3 = not filled. The gap universe is `physician_data`, not the
#' panel. Movers are never filled, since `unambiguous` fails for them by construction. See
#' CLAUDE.md for the reasoning behind each gate.
#'
#' @param panel path to the dataset from `physician_year_panel()`
#' @param physician_data paths to the per-year physician datasets -- the gap universe
#' @param l2_extracts resolved L2 leaf paths; state-years absent from this had no data
#' @param min_fill_prob probability an anchor year must reach to be usable as evidence
#' @param max_fill_zip_dist miles the best anchor's voter may be from the practice address
#'
#' @return one row per physician-year gap, carrying each gate and a `fill_tier`
classify_panel_gaps <- function(panel, physician_data, l2_extracts,
                                min_fill_prob = 0.9, max_fill_zip_dist = 50) {
  universe <- arrow::open_dataset(unique(dirname(physician_data))) |>
    dplyr::select(npi, year, state) |>
    dplyr::distinct() |>
    dplyr::collect() |>
    dplyr::mutate(year = as.integer(year))

  matched <- arrow::open_dataset(panel) |>
    dplyr::select(npi, year, LALVOTERID, match_prob, zip_dist) |>
    dplyr::collect() |>
    dplyr::mutate(year = as.integer(year))

  l2_present <- tibble::tibble(
    state = get_l2_state(l2_extracts),
    year = as.integer(get_l2_year(l2_extracts)),
    l2 = TRUE
  ) |>
    dplyr::distinct()

  anchor_rows <- matched |>
    dplyr::filter(!is.na(match_prob), match_prob >= min_fill_prob) |>
    dplyr::left_join(universe |>
                       dplyr::select(npi, year, anchor_state = state),
                     by = dplyr::join_by(npi, year))

  anchor_summary <- anchor_rows |>
    dplyr::group_by(npi) |>
    dplyr::summarize(
      n_anchor_years = dplyr::n_distinct(year),
      n_anchor_voters = dplyr::n_distinct(LALVOTERID),
      n_anchor_states = dplyr::n_distinct(anchor_state),
      anchor_state = dplyr::first(anchor_state),
      .groups = "drop"
    )

  best_anchor <- anchor_rows |>
    dplyr::arrange(dplyr::desc(match_prob), LALVOTERID, year) |>
    dplyr::group_by(npi) |>
    dplyr::slice_head(n = 1) |>
    dplyr::ungroup() |>
    dplyr::select(npi,
                  fill_LALVOTERID = LALVOTERID,
                  anchor_match_prob = match_prob,
                  anchor_zip_dist = zip_dist,
                  anchor_year = year)

  universe |>
    dplyr::anti_join(matched, by = dplyr::join_by(npi, year)) |>
    dplyr::left_join(anchor_summary, by = dplyr::join_by(npi)) |>
    dplyr::left_join(best_anchor, by = dplyr::join_by(npi)) |>
    dplyr::left_join(l2_present, by = dplyr::join_by(state, year)) |>
    dplyr::mutate(
      l2_present = !is.na(l2),
      has_anchor = !is.na(fill_LALVOTERID),
      unambiguous = !is.na(n_anchor_voters) & n_anchor_voters == 1,
      # !is.na(anchor_state) is required: n_distinct() counts NA as a value
      state_stable = !is.na(n_anchor_states) & n_anchor_states == 1 &
        !is.na(anchor_state) & anchor_state == state,
      near = !is.na(anchor_zip_dist) & anchor_zip_dist <= max_fill_zip_dist,
      fillable = has_anchor & unambiguous & state_stable & near,
      fill_tier = dplyr::case_when(
        fillable & !l2_present ~ 1L,
        fillable               ~ 2L,
        .default = 3L
      )
    ) |>
    dplyr::select(-l2) |>
    # arrow's distinct() ordering is not stable between calls; impose one
    dplyr::arrange(npi, year)
}


#' The physician-year panel, with confident gaps filled
#'
#' @description The panel's rows unchanged, plus one row per fillable gap. A separate target
#' so nothing downstream starts seeing imputed rows by accident. Filled rows carry a
#' `LALVOTERID` and `NA` for every scored attribute -- there is no model output for a year
#' that was never scored.
#'
#' A fill asserts *this physician is this voter* in a year where that was not observed. Safe
#' for appending time-invariant voter attributes; **unsafe wherever registration or turnout
#' is the outcome**, since in Tier 2 the absence may itself be the finding. Filter on
#' `filled` or `fill_tier`.
#'
#' @param panel path to the dataset from `physician_year_panel()`
#' @param physician_data paths to the per-year physician datasets
#' @param l2_extracts resolved L2 leaf paths
#' @param out_pth directory to write to
#' @param min_fill_prob,max_fill_zip_dist passed to `classify_panel_gaps()`
#'
#' @return `out_pth` -- the panel plus filled rows, with `filled` and `fill_tier`
fill_panel_gaps <- function(panel, physician_data, l2_extracts,
                            out_pth = "trunk/derived/physician_year_panel_filled",
                            min_fill_prob = 0.9, max_fill_zip_dist = 50) {
  if (rlang::is_empty(panel) || rlang::is_empty(physician_data)) {
    return(NULL)
  }

  unlink(out_pth, recursive = TRUE)

  observed <- arrow::open_dataset(panel) |>
    dplyr::collect() |>
    dplyr::mutate(year = as.integer(year),
                  filled = FALSE,
                  fill_tier = NA_integer_)

  filled <- classify_panel_gaps(panel, physician_data, l2_extracts,
                                min_fill_prob = min_fill_prob,
                                max_fill_zip_dist = max_fill_zip_dist) |>
    dplyr::filter(fill_tier %in% c(1L, 2L)) |>
    dplyr::transmute(
      npi,
      year,
      LALVOTERID = fill_LALVOTERID,
      match_prob = NA_real_,
      state_agree = NA,
      zip_dist = NA_real_,
      full_name_sim = NA_real_,
      n = NA_integer_,
      tied = NA,
      filled = TRUE,
      fill_tier
    )

  assertthat::assert_that(
    !anyDuplicated(filled[c("npi", "year")]),
    msg = cli::format_error("Gap fills must be unique per {.var npi}-{.var year}")
  )

  dplyr::bind_rows(observed, filled) |>
    arrow::write_dataset(out_pth)

  return_out_pth(out_pth)
}


#' How many panel gaps there are, and why they were or were not filled
#'
#' @description The gap ledger by tier, and which gate failed for the unfilled ones. Gates
#' overlap, so the `n_fail_*` columns do not sum to `n_tier_3`. Worth reading before trusting
#' the filled panel: if `n_tier_2` dwarfs `n_tier_1`, most fills rest on the weaker
#' inference. In-memory: `targets::tar_read(panel_gap_summary)`.
#'
#' @inheritParams classify_panel_gaps
#'
#' @return a one-row tibble of counts
summarize_panel_gaps <- function(panel, physician_data, l2_extracts,
                                 min_fill_prob = 0.9, max_fill_zip_dist = 50) {
  classify_panel_gaps(panel, physician_data, l2_extracts,
                      min_fill_prob = min_fill_prob,
                      max_fill_zip_dist = max_fill_zip_dist) |>
    dplyr::summarize(
      n_gaps = dplyr::n(),
      n_npi_with_gap = dplyr::n_distinct(npi),
      n_tier_1 = sum(fill_tier == 1L),
      n_tier_2 = sum(fill_tier == 2L),
      n_tier_3 = sum(fill_tier == 3L),
      n_fail_no_anchor = sum(fill_tier == 3L & !has_anchor),
      n_fail_ambiguous = sum(fill_tier == 3L & has_anchor & !unambiguous),
      n_fail_moved = sum(fill_tier == 3L & has_anchor & !state_stable),
      n_fail_far = sum(fill_tier == 3L & has_anchor & !is.na(anchor_zip_dist) &
                               anchor_zip_dist > max_fill_zip_dist),
      n_fail_no_zip = sum(fill_tier == 3L & has_anchor & is.na(anchor_zip_dist)),
      n_no_l2_unfilled = sum(fill_tier == 3L & !l2_present)
    )
}
