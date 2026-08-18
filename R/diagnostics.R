#' Best scored row per physician-year
#'
#' @description The shared reduction behind the diagnostics: one row per (npi, year), the
#' highest-probability candidate. Ties broken by `LALVOTERID` then `year`, the same
#' deterministic order `reconcile_physician_matches()` uses.
#'
#' Filled rows are excluded here and counted separately. They carry an identity but no
#' `match_prob`, so they cannot sit on a probability axis -- treating them as 0 would
#' understate them and as 1 would overstate them.
#'
#' @param panel path to `physician_year_panel_filled` (or the unfilled panel)
#'
#' @return a tibble of one row per npi-year, plus a `filled` flag column if present
best_scored_per_physician_year <- function(panel) {
  cols <- names(arrow::open_dataset(panel))
  wanted <- intersect(c("npi", "year", "LALVOTERID", "match_prob", "state_agree",
                        "zip_dist", "full_name_sim", "n", "tied", "filled", "fill_tier"),
                      cols)

  d <- arrow::open_dataset(panel) |>
    dplyr::select(dplyr::all_of(wanted)) |>
    dplyr::collect()

  if (!"filled" %in% names(d)) {
    d$filled <- FALSE
  }

  d |>
    dplyr::filter(!filled) |>
    dplyr::arrange(dplyr::desc(match_prob), LALVOTERID, year) |>
    dplyr::group_by(npi, year) |>
    dplyr::slice_head(n = 1) |>
    dplyr::ungroup()
}


#' Physician-years available to match, by year
#'
#' @description The denominator. Two of them, because they answer different questions:
#' `n_physicians` is every physician-year in `physician_data`, and
#' `n_physicians_l2` excludes those whose practice state had no L2 partition that year --
#' 2024 MD, MS and NV. Reporting only the first makes 2024 look like a matching failure when
#' it is a data gap.
#'
#' @param physician_data paths to the per-year physician datasets
#' @param l2_extracts resolved L2 leaf paths
#'
#' @return a tibble of `year`, `n_physicians`, `n_physicians_l2`
physician_year_universe <- function(physician_data, l2_extracts) {
  universe <- arrow::open_dataset(unique(dirname(physician_data))) |>
    dplyr::select(npi, year, state) |>
    dplyr::distinct() |>
    dplyr::collect() |>
    dplyr::mutate(year = as.integer(year))

  l2_present <- tibble::tibble(state = get_l2_state(l2_extracts),
                               year = as.integer(get_l2_year(l2_extracts)),
                               l2 = TRUE) |>
    dplyr::distinct()

  universe |>
    dplyr::left_join(l2_present, by = dplyr::join_by(state, year)) |>
    dplyr::group_by(year) |>
    dplyr::summarize(n_physicians = dplyr::n_distinct(npi),
                     n_physicians_l2 = dplyr::n_distinct(npi[!is.na(l2)]),
                     .groups = "drop")
}


#' Match rate as a function of the minimum accepted probability
#'
#' @description The headline diagnostic: for each year and each candidate cutoff, what share
#' of physicians end up with a match. Read it as a precision/recall dial -- moving right
#' discards weaker matches, and the slope tells you how much you give up to do so.
#'
#' A steep drop somewhere in the middle means the model is genuinely separating matches from
#' non-matches. A gentle, near-linear decline means it is hedging, and no cutoff is defensible.
#'
#' Pooled figures are recoverable by summing the counts rather than averaging the percentages:
#' `sum(n_matched)/sum(n_physicians)`.
#'
#' @param panel path to `physician_year_panel_filled`
#' @param physician_data paths to the per-year physician datasets, for the denominator
#' @param l2_extracts resolved L2 leaf paths, for the L2-available denominator
#' @param thresholds probability cutoffs to evaluate
#'
#' @return a tibble of one row per year-threshold
match_rate_by_threshold <- function(panel, physician_data, l2_extracts,
                                    thresholds = seq(0, 0.99, by = 0.01)) {
  best <- best_scored_per_physician_year(panel)
  denom <- physician_year_universe(physician_data, l2_extracts)

  filled_counts <- arrow::open_dataset(panel) |>
    dplyr::select(dplyr::any_of(c("npi", "year", "filled"))) |>
    dplyr::collect()
  filled_counts <- if ("filled" %in% names(filled_counts)) {
    filled_counts |>
      dplyr::filter(filled) |>
      dplyr::group_by(year) |>
      dplyr::summarize(n_filled = dplyr::n_distinct(npi), .groups = "drop")
  } else {
    tibble::tibble(year = integer(0), n_filled = integer(0))
  }

  grid <- tidyr::expand_grid(year = sort(unique(best$year)), threshold = thresholds)

  grid |>
    dplyr::mutate(
      n_matched = purrr::map2_int(year, threshold, \(y, t)
        sum(best$year == y & !is.na(best$match_prob) & best$match_prob >= t)),
      n_cross_border = purrr::map2_int(year, threshold, \(y, t)
        sum(best$year == y & !is.na(best$match_prob) & best$match_prob >= t &
              !is.na(best$state_agree) & !best$state_agree))
    ) |>
    dplyr::left_join(denom, by = dplyr::join_by(year)) |>
    dplyr::left_join(filled_counts, by = dplyr::join_by(year)) |>
    dplyr::mutate(
      n_filled = dplyr::coalesce(n_filled, 0L),
      pct_matched = 100*n_matched/n_physicians,
      pct_matched_l2 = 100*n_matched/n_physicians_l2,
      pct_cross_border = dplyr::if_else(n_matched > 0,
                                       100*n_cross_border/n_matched, NA_real_)
    )
}


#' Plot the match-rate curve
#'
#' @description One line per year, plus a pooled line. Writes both a pdf and a png -- the pdf
#' for anything that ends up in a manuscript, the png because it is what actually gets pasted
#' into a message.
#'
#' Uses `pct_matched_l2`, i.e. the denominator that excludes physician-years with no L2
#' partition, so the 2024 line is comparable with the rest instead of sitting artificially low.
#'
#' @param rate_table tibble from `match_rate_by_threshold()`
#' @param out_dir directory to write into
#'
#' @return the paths written
plot_match_rate_curve <- function(rate_table, out_dir = "trunk/analysis") {
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  pooled <- rate_table |>
    dplyr::group_by(threshold) |>
    dplyr::summarize(pct_matched_l2 = 100*sum(n_matched)/sum(n_physicians_l2),
                     .groups = "drop")

  p <- ggplot2::ggplot(rate_table,
                       ggplot2::aes(x = threshold, y = pct_matched_l2,
                                    group = factor(year), colour = factor(year))) +
    ggplot2::geom_line(alpha = 0.65) +
    ggplot2::geom_line(data = pooled,
                       ggplot2::aes(x = threshold, y = pct_matched_l2),
                       inherit.aes = FALSE, linewidth = 1.1, colour = "black") +
    ggplot2::scale_y_continuous(limits = c(0, 100)) +
    ggplot2::labs(x = "Minimum accepted match probability",
                  y = "Physicians with a match (%)",
                  colour = "Year",
                  title = "Match rate by minimum match quality",
                  subtitle = paste("Black line pools all years. Denominator excludes",
                                   "physician-years with no L2 partition.")) +
    ggplot2::theme_minimal()

  pdf_pth <- file.path(out_dir, "match_rate_by_threshold.pdf")
  png_pth <- file.path(out_dir, "match_rate_by_threshold.png")
  ggplot2::ggsave(pdf_pth, p, width = 7, height = 4.5)
  ggplot2::ggsave(png_pth, p, width = 7, height = 4.5, dpi = 150)

  c(pdf_pth, png_pth)
}


#' Match quality per state-year
#'
#' @description Where a systematic problem would actually show up. A state whose L2 extract
#' was malformed, or whose name fields are encoded differently, appears here as a match rate
#' far below its neighbours -- which the national curve would average away.
#'
#' The panel carries no `state` column, so practice state comes from joining back to
#' `physician_data`.
#'
#' @param panel path to `physician_year_panel_filled`
#' @param physician_data paths to the per-year physician datasets
#' @param min_prob cutoff at which the match rate is reported
#'
#' @return a tibble of one row per state-year
match_quality_by_state_year <- function(panel, physician_data, min_prob = 0.9) {
  universe <- arrow::open_dataset(unique(dirname(physician_data))) |>
    dplyr::select(npi, year, state) |>
    dplyr::distinct() |>
    dplyr::collect() |>
    dplyr::mutate(year = as.integer(year))

  best <- best_scored_per_physician_year(panel) |>
    dplyr::mutate(year = as.integer(year))

  universe |>
    dplyr::left_join(best, by = dplyr::join_by(npi, year)) |>
    dplyr::group_by(state, year) |>
    dplyr::summarize(
      n_physicians = dplyr::n_distinct(npi),
      n_any_candidate = sum(!is.na(match_prob)),
      n_matched = sum(!is.na(match_prob) & match_prob >= min_prob),
      pct_matched = 100*n_matched/n_physicians,
      median_match_prob = stats::median(match_prob, na.rm = TRUE),
      median_zip_dist = stats::median(zip_dist, na.rm = TRUE),
      pct_cross_border = 100*mean(!state_agree, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::arrange(pct_matched)
}


#' Distribution of the match features among best candidates
#'
#' @description Quantiles of everything the model saw, plus `match_prob` by candidate-count
#' bucket. That last one is the first look at the `n` dilution recorded in CLAUDE.md: if mean
#' `match_prob` falls sharply as `n` rises, candidate count is doing more work than name
#' commonness alone would justify.
#'
#' @param panel path to `physician_year_panel_filled`
#'
#' @return a list of two tibbles, `quantiles` and `by_candidate_count`
match_feature_summary <- function(panel) {
  best <- best_scored_per_physician_year(panel)
  probs <- c(0.01, 0.05, 0.1, 0.25, 0.5, 0.75, 0.9, 0.95, 0.99)

  quantiles <- c("match_prob", "zip_dist", "full_name_sim", "n") |>
    purrr::map(\(v) tibble::tibble(
      variable = v,
      quantile = probs,
      value = stats::quantile(best[[v]], probs = probs, na.rm = TRUE),
      pct_na = 100*mean(is.na(best[[v]]))
    )) |>
    purrr::list_rbind()

  by_candidate_count <- best |>
    dplyr::mutate(n_bucket = cut(n, breaks = c(0, 1, 2, 3, 5, 10, 25, Inf),
                                 labels = c("1", "2", "3", "4-5", "6-10", "11-25", "26+"))) |>
    dplyr::group_by(n_bucket) |>
    dplyr::summarize(n_physician_years = dplyr::n(),
                     mean_match_prob = mean(match_prob, na.rm = TRUE),
                     median_match_prob = stats::median(match_prob, na.rm = TRUE),
                     .groups = "drop")

  list(quantiles = quantiles, by_candidate_count = by_candidate_count)
}


#' Which features the forest actually uses
#'
#' @description `grf`'s split-based importance, labelled with the feature names the model was
#' fitted on. Worth reading against the notes in CLAUDE.md: occupation was added as two
#' indicators on the argument that missing and non-medical are different states, and
#' `state_agree` was deliberately left out on the argument that `zip_dist` already carries it.
#' Both claims are checkable here.
#'
#' Importance is relative and split-count based, so treat it as a ranking rather than a
#' variance decomposition.
#'
#' @param rf_model fitted model from `train_rf_model()`
#'
#' @return a tibble of `feature`, `importance`, ordered most important first
rf_variable_importance <- function(rf_model) {
  vi <- as.numeric(grf::variable_importance(rf_model))
  feat <- colnames(rf_model$X.orig)

  if (is.null(feat) || length(feat) != length(vi)) {
    feat <- paste0("feature_", seq_along(vi))
  }

  tibble::tibble(feature = feat, importance = vi) |>
    dplyr::arrange(dplyr::desc(importance))
}


#' Label each filled physician-year by how well anchored it is
#'
#' @description "Confident" needs a definition, and two are available without assuming
#' anything about the run's settings:
#'
#' - **`interior`** — the physician has a *scored* row for the **same** `LALVOTERID` both
#'   before and after the gap year, so the identity is bracketed rather than extrapolated off
#'   the end of the panel. Uses the fill's own voter id, so no probability threshold has to be
#'   guessed at.
#' - **`fill_tier == 1`** — no L2 partition existed that year, so the physician could not
#'   have matched. Absence carries no information about them, which is why this is the stronger
#'   tier. Tier 2 means L2 existed and they were not found, which is ambiguous evidence
#'   *against*.
#'
#' Every filled row already cleared the four gates in `classify_panel_gaps()` — a strong
#' unambiguous anchor, a stable practice state, and a nearby anchor address. These two labels
#' are further narrowing on top of that, not a substitute for it.
#'
#' @section Inherited quality:
#'
#' A fill has no `match_prob` of its own, but the rows that sourced it do. `anchor_prob_mean`
#' is the mean `match_prob` across the physician's scored rows for the **same** `LALVOTERID`
#' that clear `min_anchor_prob` -- the average the fill was extrapolated from. `_min` and
#' `_max` are given too, since a mean over two anchors of 0.99 and 0.91 is a different claim
#' from a mean over one of 0.95.
#'
#' **`min_anchor_prob` must match the `min_fill_prob` the run used** (both default to 0.9).
#' Set it higher than the run did and some fills will show no anchors at all, leaving
#' `anchor_prob_mean` as `NA`. Filtering on probability rather than taking every scored row for
#' that voter is deliberate: a physician can hold the same voter at 0.95 in one year and 0.4 in
#' another, and only the first was ever an anchor.
#'
#' Note the inherited value is an **upper bound**. It carries no penalty for the extrapolation
#' itself, so a filled year labelled 0.97 is not as good as an observed year labelled 0.97.
#'
#' @param panel path to `physician_year_panel_filled`
#' @param min_anchor_prob probability a scored row must clear to count as an anchor
#'
#' @return a tibble of the filled rows with `interior`, `tier1` and the anchor-quality columns
classify_fill_confidence <- function(panel, min_anchor_prob = 0.9) {
  d <- arrow::open_dataset(panel) |>
    dplyr::select(dplyr::any_of(c("npi", "year", "LALVOTERID", "match_prob", "filled",
                                  "fill_tier"))) |>
    dplyr::collect() |>
    dplyr::mutate(year = as.integer(year))

  if (!"filled" %in% names(d)) {
    return(tibble::tibble(npi = numeric(0), year = integer(0), LALVOTERID = character(0),
                          fill_tier = integer(0), interior = logical(0), tier1 = logical(0),
                          n_anchors = integer(0), anchor_prob_mean = numeric(0),
                          anchor_prob_min = numeric(0), anchor_prob_max = numeric(0)))
  }

  scored <- dplyr::filter(d, !filled)

  # bracket range per (physician, voter) among SCORED rows only
  span <- scored |>
    dplyr::group_by(npi, LALVOTERID) |>
    dplyr::summarize(first_year = min(year), last_year = max(year), .groups = "drop")

  # the rows that actually sourced the fill: same voter, clearing the anchor cutoff
  anchors <- scored |>
    dplyr::filter(!is.na(match_prob), match_prob >= min_anchor_prob) |>
    dplyr::group_by(npi, LALVOTERID) |>
    dplyr::summarize(n_anchors = dplyr::n(),
                     anchor_prob_mean = mean(match_prob),
                     # guarded: dplyr evaluates these once on a zero-row group to infer output
                     # types, and min()/max() on nothing warns and returns +/-Inf
                     anchor_prob_min = if (dplyr::n()) min(match_prob) else NA_real_,
                     anchor_prob_max = if (dplyr::n()) max(match_prob) else NA_real_,
                     .groups = "drop")

  d |>
    dplyr::filter(filled) |>
    dplyr::left_join(span, by = dplyr::join_by(npi, LALVOTERID)) |>
    dplyr::left_join(anchors, by = dplyr::join_by(npi, LALVOTERID)) |>
    dplyr::mutate(
      interior = !is.na(first_year) & year > first_year & year < last_year,
      tier1 = !is.na(fill_tier) & fill_tier == 1L,
      n_anchors = dplyr::coalesce(n_anchors, 0L)
    ) |>
    dplyr::select(npi, year, LALVOTERID, fill_tier, interior, tier1,
                  n_anchors, anchor_prob_mean, anchor_prob_min, anchor_prob_max)
}


#' Match rate counting confident fills as matches
#'
#' @description The companion to `match_rate_by_threshold()`, which excludes fills entirely.
#' Here a fill counts toward the numerator, under each of several definitions of "confident",
#' so the definitions can be compared rather than chosen blind.
#'
#' | `fill_rule` | Counts as a match |
#' | --- | --- |
#' | `none` | scored matches only — identical to `match_rate_by_threshold()` |
#' | `interior` | fills bracketed by the same voter on both sides |
#' | `tier1` | fills where no L2 partition existed that year |
#' | `interior_or_tier1` | either of the above |
#' | `any` | every fill |
#'
#' Two numerators are reported for each rule, because there are two defensible readings:
#'
#' - **`n_matched_incl_fills`** — a qualifying fill counts at *every* threshold. Fills have no
#'   probability of their own, so the same set is added throughout. Reads as: a confident fill
#'   is a match however strictly the scored ones are cut.
#' - **`n_matched_incl_fills_q`** — a fill counts only where its **inherited** quality clears
#'   the threshold. `anchor_prob_mean` from `classify_fill_confidence()` puts the fill *on* the
#'   probability axis, so fills form a curve rather than a constant, and a fill sourced from a
#'   0.93 anchor drops out at a 0.95 cutoff exactly as a scored 0.93 match would.
#'
#' The second is the more conservative and usually the more useful. A fill whose anchors did
#' not clear `min_anchor_prob` has `anchor_prob_mean` of `NA` and never counts toward it.
#'
#' @section What this cannot rescue:
#'
#' A fill exists only where the physician-year was **absent from the panel entirely**. A
#' physician-year with one weak candidate — say `match_prob` of 0.02 — is not a gap, so it was
#' never a fill candidate. At a cutoff of 0.9 it therefore counts as neither matched nor
#' filled.
#'
#' Making fills rescue those too would mean re-deriving the gap universe at every threshold,
#' which is a change to `fill_panel_gaps()` rather than to a diagnostic. Recorded in CLAUDE.md
#' as a deferred idea.
#'
#' @inheritParams match_rate_by_threshold
#'
#' @return a tibble of one row per year-threshold-`fill_rule`
match_rate_with_fills <- function(panel, physician_data, l2_extracts,
                                  thresholds = seq(0, 0.99, by = 0.01),
                                  min_anchor_prob = 0.9) {
  scored <- match_rate_by_threshold(panel, physician_data, l2_extracts,
                                    thresholds = thresholds)
  fills <- classify_fill_confidence(panel, min_anchor_prob = min_anchor_prob)

  rules <- list(none = \(f) f[0, ],
                interior = \(f) f[f$interior, ],
                tier1 = \(f) f[f$tier1, ],
                interior_or_tier1 = \(f) f[f$interior | f$tier1, ],
                any = \(f) f)

  names(rules) |>
    purrr::map(\(rule) {
      kept <- rules[[rule]](fills)

      flat <- kept |>
        dplyr::group_by(year) |>
        dplyr::summarize(n_fill_counted = dplyr::n_distinct(npi), .groups = "drop")

      scored |>
        dplyr::left_join(flat, by = dplyr::join_by(year)) |>
        dplyr::mutate(
          fill_rule = rule,
          n_fill_counted = dplyr::coalesce(n_fill_counted, 0L),
          # fills counted only where their INHERITED quality clears the threshold
          n_fill_counted_q = purrr::map2_int(year, threshold, \(y, t)
            length(unique(kept$npi[kept$year == y & !is.na(kept$anchor_prob_mean) &
                                     kept$anchor_prob_mean >= t]))),
          n_matched_incl_fills = n_matched + n_fill_counted,
          n_matched_incl_fills_q = n_matched + n_fill_counted_q,
          pct_matched_incl_fills = 100*n_matched_incl_fills/n_physicians,
          pct_matched_incl_fills_q = 100*n_matched_incl_fills_q/n_physicians,
          pct_matched_incl_fills_l2 = 100*n_matched_incl_fills/n_physicians_l2
        )
    }) |>
    purrr::list_rbind()
}


#' Plot the match-rate curve with and without confident fills
#'
#' @description Pooled across years, one line per `fill_rule`, so the gain from counting fills
#' is legible as the gap between lines rather than having to be inferred across two figures.
#'
#' Uses the full `n_physicians` denominator here rather than the L2-available one, because
#' Tier 1 fills exist precisely where L2 was missing — dividing them by a denominator that has
#' already removed those physician-years would double-count the correction and can push the
#' rate above 100%.
#'
#' @param rate_table tibble from `match_rate_with_fills()`
#' @param out_dir directory to write into
#'
#' @return the paths written
plot_match_rate_with_fills <- function(rate_table, out_dir = "trunk/analysis") {
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  pooled <- rate_table |>
    dplyr::group_by(fill_rule, threshold) |>
    dplyr::summarize(flat = 100*sum(n_matched_incl_fills)/sum(n_physicians),
                     inherited = 100*sum(n_matched_incl_fills_q)/sum(n_physicians),
                     .groups = "drop") |>
    tidyr::pivot_longer(c(flat, inherited), names_to = "counting", values_to = "pct") |>
    dplyr::mutate(fill_rule = factor(fill_rule,
                                     levels = c("none", "interior", "tier1",
                                                "interior_or_tier1", "any")),
                  counting = factor(counting, levels = c("flat", "inherited"),
                                    labels = c("at every cutoff",
                                               "at its inherited quality")))

  p <- ggplot2::ggplot(pooled, ggplot2::aes(x = threshold, y = pct,
                                            colour = fill_rule)) +
    ggplot2::geom_line(linewidth = 0.9) +
    ggplot2::facet_wrap(~counting) +
    ggplot2::scale_y_continuous(limits = c(0, 100)) +
    ggplot2::labs(x = "Minimum accepted match probability",
                  y = "Physicians with a match (%)",
                  colour = "Fills counted",
                  title = "Match rate, counting confident gap fills as matches",
                  subtitle = paste("Pooled across years. Left: a qualifying fill counts",
                                   "throughout. Right: only where the mean probability of",
                                   "its source years clears the cutoff.")) +
    ggplot2::theme_minimal()

  pdf_pth <- file.path(out_dir, "match_rate_with_fills.pdf")
  png_pth <- file.path(out_dir, "match_rate_with_fills.png")
  ggplot2::ggsave(pdf_pth, p, width = 7, height = 4.5)
  ggplot2::ggsave(png_pth, p, width = 7, height = 4.5, dpi = 150)

  c(pdf_pth, png_pth)
}
