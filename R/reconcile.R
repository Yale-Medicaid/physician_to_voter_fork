#' Best match per physician-year
#'
#' @description Collapses the scored candidate pairs to one row per (npi, year): the
#' voter that year's model liked best.
#'
#' Ties are **kept and flagged**, not silently dropped. Two candidates at identical
#' probability is a real state of affairs worth seeing, and dropping the physician would
#' quietly shrink the panel.
#'
#' No `match_prob` cutoff is applied. Thresholding is left to whoever consumes this, so
#' every physician with any candidate appears, however weak — filter on `match_prob`
#' downstream.
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

	# scored_pairs is partitioned by year ALONE, so its root is one dirname() up -- unlike
	# lsh_pairs / cross_border_pairs, which are year=/state= and need two.
	root <- unique(dirname(scored_pairs))

	open_dataset(root) %>%
		select(npi, year, LALVOTERID, match_prob, state_agree, zip_dist, full_name_sim, n) %>%
		collect() %>%
		group_by(npi, year) %>%
		filter(match_prob == max(match_prob)) %>%
		mutate(tied = n() > 1) %>%
		ungroup() %>%
		write_dataset(out_pth)

	return_out_pth(out_pth)
}


#' One best match per physician, across all years
#'
#' @description Reduces the physician-year panel to a single row per NPI: the highest
#' probability match found in any year, plus enough context to tell why.
#'
#' **Ties.** Two flags, because there are two kinds. `any_tied_in_year` comes from the panel
#' and marks a year in which two candidates tied for that year's best. `best_is_tied` marks
#' the physician-level case: two or more rows tie for the overall best, possibly in
#' different years, which the panel flag cannot see. Exactly one row per NPI is still
#' emitted -- the tie is broken deterministically by `LALVOTERID` ascending, which is
#' arbitrary but reproducible -- and `best_is_tied` records that the choice was made.
#'
#' `mover` is TRUE when a physician's best-matching voter is not the same in every year
#' they appear. Note what that does and does not mean: it says the best match *changed*,
#' which is consistent with a genuine move but equally with two similar voters trading
#' places between years. It is a flag to investigate, not a finding.
#'
#' Physicians with no data in a given year -- 2024 MD, MS and NV -- simply have fewer rows
#' in the panel and a lower `n_years_matched`. That is structural absence and needs no
#' special case; it must not be read as a failure to match.
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

	open_dataset(panel) %>%
		collect() %>%
		group_by(npi) %>%
		mutate(
			n_years_matched   = n_distinct(year),
			n_distinct_voters = n_distinct(LALVOTERID),
			# the best-matching voter is not the same every year
			mover             = n_distinct(LALVOTERID) > 1,
			# a year in which two candidates tied for that year's best
			any_tied_in_year  = any(tied),
			# two or more DISTINCT voters tie for this physician's overall best, possibly
			# in different years -- the panel-level flag above does not see those. Counting
			# rows rather than distinct voters would wrongly flag the common case of the
			# same voter matching equally well in several years, which is not ambiguity.
			best_is_tied      = n_distinct(LALVOTERID[match_prob == max(match_prob)]) > 1
		) %>%
		# Deterministic tie-break: LALVOTERID then year, both ascending. Arbitrary but
		# reproducible, which matters more -- slice_max(with_ties = FALSE) alone would
		# return whichever row happened to come first in the input. `year` is in the key
		# so that the same voter matching equally well in several years yields a stable
		# `best_year` rather than an arbitrary one. `best_is_tied` records that a choice
		# between distinct voters was made at all.
		arrange(desc(match_prob), LALVOTERID, year, .by_group = TRUE) %>%
		slice_head(n = 1) %>%
		ungroup() %>%
		transmute(
			npi,
			best_LALVOTERID = LALVOTERID,
			best_match_prob = match_prob,
			best_year       = year,
			n_years_matched, n_distinct_voters, mover,
			any_tied_in_year, best_is_tied,
			# was the chosen best match found across a state line
			best_cross_border = !state_agree
		) %>%
		write_dataset(out_pth)

	return_out_pth_check_distinct(out_pth, distinct_col = "npi")
}
