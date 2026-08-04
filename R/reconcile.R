#' Best match per physician-year
#'
#' @description One row per (npi, year): the voter that year's model liked best. Ties are
#' kept and flagged rather than dropped, and no `match_prob` cutoff is applied -- thresholding
#' is the consumer's choice.
#'
#' @param scored_pairs paths to the per-year scored datasets from `score_pairs()`
#' @param out_pth directory to write to
#'
#' @return `out_pth` — one row per (npi, year), or more where a year has tied candidates
physician_year_panel <- function(scored_pairs,
                                 out_pth = "trunk/derived/physician_year_panel") {
  if (rlang::is_empty(scored_pairs)) {
    return(NULL)
  }

  unlink(out_pth, recursive = TRUE)

  # scored_pairs is partitioned by year alone, so its root is one dirname() up
  root <- unique(dirname(scored_pairs))

  arrow::open_dataset(root) |>
    dplyr::select(npi, year, LALVOTERID, match_prob, state_agree, zip_dist, full_name_sim, n) |>
    dplyr::collect() |>
    dplyr::group_by(npi, year) |>
    dplyr::filter(match_prob == max(match_prob)) |>
    dplyr::mutate(tied = dplyr::n() > 1) |>
    dplyr::ungroup() |>
    arrow::write_dataset(out_pth)

  return_out_pth(out_pth)
}


#' One best match per physician, across all years
#'
#' @description One row per NPI: the highest-probability match in any year, plus enough
#' context to tell why. Two tie flags, because there are two kinds -- `any_tied_in_year`
#' within a year, `best_is_tied` across years, which the panel flag cannot see. Ties are
#' broken deterministically by `LALVOTERID` then `year`.
#'
#' `mover` means only that the best-matching voter *changed* -- equally consistent with a
#' real move and with two similar voters trading places. A flag to investigate, not a
#' finding. See CLAUDE.md.
#'
#' @param panel path to the dataset from `physician_year_panel()`
#' @param out_pth directory to write to
#'
#' @return `out_pth` -- one row per npi, asserted distinct
reconcile_physician_matches <- function(panel,
                                        out_pth = "trunk/derived/physician_matches") {
  if (rlang::is_empty(panel)) {
    return(NULL)
  }

  unlink(out_pth, recursive = TRUE)

  arrow::open_dataset(panel) |>
    dplyr::collect() |>
    dplyr::group_by(npi) |>
    dplyr::mutate(
      n_years_matched = dplyr::n_distinct(year),
      n_distinct_voters = dplyr::n_distinct(LALVOTERID),
      mover = dplyr::n_distinct(LALVOTERID) > 1,
      any_tied_in_year = any(tied),
      best_is_tied = dplyr::n_distinct(LALVOTERID[match_prob == max(match_prob)]) > 1
    ) |>
    dplyr::arrange(dplyr::desc(match_prob), LALVOTERID, year, .by_group = TRUE) |>
    dplyr::slice_head(n = 1) |>
    dplyr::ungroup() |>
    dplyr::transmute(
      npi,
      best_LALVOTERID = LALVOTERID,
      best_match_prob = match_prob,
      best_year = year,
      n_years_matched, n_distinct_voters, mover,
      any_tied_in_year, best_is_tied,
      best_cross_border = !state_agree
    ) |>
    arrow::write_dataset(out_pth)

  return_out_pth_check_distinct(out_pth, distinct_col = "npi")
}
