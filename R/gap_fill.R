#' Classify every empty physician-year in the panel
#'
#' @description A physician can be absent from a year of the panel for two quite different
#' reasons, and the distinction is the whole point of this step:
#'
#' - **No L2 data existed** for the state they practised in that year (2024 MD, MS and NV).
#'   Matching was *impossible*, so absence carries no information about the physician.
#' - **L2 existed and they were not matched.** Absence is now evidence, though ambiguous
#'   evidence: they may not have been registered, or the match may simply have failed.
#'
#' Filling the first case is close to free. Filling the second trades a false negative for a
#' possible false positive, so it is gated harder.
#'
#' **The universe of gaps is `physician_data`, not the panel.** A gap only exists where the
#' physician had an NPI record that year -- otherwise there is nothing to fill and no claim
#' to make.
#'
#' @section The gates:
#'
#' A gap is fillable only when all four hold. Every one of them can fail to `NA`, and `NA`
#' is treated as failure throughout -- absence of evidence is not evidence here.
#'
#' | Gate | Requirement | Why |
#' |---|---|---|
#' | `has_anchor` | at least one year matched at `match_prob >= min_fill_prob` | the panel applies no cutoff, so a physician's only "match" may be near-zero. Filling from that would manufacture a link out of noise. |
#' | `unambiguous` | exactly one distinct `LALVOTERID` across the anchor years | two voters means we do not know which identity to carry into the gap. This also excludes tied anchors. |
#' | `state_stable` | the gap year's practice state equals the anchor years' single practice state | a physician who changed practice state may well have changed registration; the link across the gap is exactly what is uncertain. |
#' | `near` | the best anchor's `zip_dist` is non-`NA` and `<= max_fill_zip_dist` | corroborates that the anchor match itself is geographically plausible. `NA` means the ZIP had no ZCTA, so proximity cannot be checked. |
#'
#' Tier is then just *why the year was empty*, given the gates passed:
#'
#' | `fill_tier` | Meaning |
#' |---|---|
#' | 1 | gates passed, and no L2 partition existed -- structural absence |
#' | 2 | gates passed, but L2 existed and the physician was not matched |
#' | 3 | gates not passed -- do not fill |
#'
#' **Movers are never filled.** `unambiguous` fails for them by construction. That is
#' deliberate: `mover` already means only that the best-matching voter *changed*, which
#' `reconcile_physician_matches()` notes is equally consistent with scoring noise. Choosing
#' one of the two records to carry across a gap would be a guess dressed as data.
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
#' @description Emits `physician_year_panel()`'s rows unchanged, plus one row per gap that
#' `classify_panel_gaps()` judged fillable. A separate target rather than a modification of
#' the panel, so the unfilled panel stays available and nothing downstream silently starts
#' seeing imputed rows.
#'
#' **Filled rows carry an identity and nothing else.** `LALVOTERID` is filled; every scored
#' attribute -- `match_prob`, `zip_dist`, `full_name_sim`, `n`, `state_agree`, `tied` -- is
#' `NA`. There is no model output for a year that was never scored, and writing the anchor
#' year's values into the gap would invent a measurement. It also makes a filled row
#' impossible to mistake for a scored one even if `filled` is ignored.
#'
#' @section What a filled row does and does not license:
#'
#' A fill asserts *this physician is this voter*, extended to a year where that was not
#' observed. So:
#'
#' - **Safe** for appending time-invariant or slow-moving voter attributes -- birth date,
#'   place of birth, race/ethnicity.
#' - **Unsafe** wherever registration or turnout is the outcome. In Tier 2 especially, the
#'   physician's absence may *be* the finding: they might genuinely not have been registered
#'   that year. Filling it and then asking "were they registered?" answers the question with
#'   the assumption.
#'
#' Filter on `filled` or `fill_tier` accordingly. No fill is applied to the tie flags, and
#' `filled = FALSE` rows are byte-for-byte the panel's.
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
#' @description Reports the gap ledger by tier and, for the unfilled ones, which gate
#' failed. Gates are not mutually exclusive, so the `n_fail_*` columns overlap and will not
#' sum to `n_tier_3`.
#'
#' Worth reading before trusting the filled panel: if `n_tier_2` dwarfs `n_tier_1`, most
#' fills rest on the weaker inference, and `min_fill_prob` / `max_fill_zip_dist` are doing
#' real work rather than acting as formalities. Small, so it stays an in-memory target:
#' `targets::tar_read(panel_gap_summary)`.
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
