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
		summarize(
			best_LALVOTERID = LALVOTERID[which.max(match_prob)],
			best_match_prob = max(match_prob),
			best_year       = year[which.max(match_prob)],
			n_years_matched = n_distinct(year),
			n_distinct_voters = n_distinct(LALVOTERID),
			# the best-matching voter is not the same every year
			mover = n_distinct(LALVOTERID) > 1,
			# any year where two candidates tied for best
			any_tied = any(tied),
			# was the best match ever found across a state line
			best_cross_border = !state_agree[which.max(match_prob)],
			.groups = "drop"
		) %>%
		write_dataset(out_pth)

	return_out_pth_check_distinct(out_pth, distinct_col = "npi")
}
