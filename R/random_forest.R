#' Make Predictor Matrix
#'
#' @description Extract the predictors used for a classification model, and format them as a
#' numeric matrix.
#'
#' **`state_agree` is deliberately NOT a feature**, though it is computed and carried.
#' Crossing a state line is not what makes a match implausible -- distance is, and
#' `zip_dist` already measures that directly. A physician living 15 miles away across a
#' border is nearer than one living 60 miles away in-state, and the model should treat them
#' accordingly.
#'
#' This also means the model transfers to cross-border pairs without new labels. The
#' training data is same-state only, but intra-state distances in large states run to
#' hundreds of miles, so `zip_dist` at (say) 67 miles is well inside the range the model has
#' already learned from -- it simply learned it from Texas rather than from a border
#' crossing. Adding `state_agree` would have contributed nothing that `zip_dist` does not
#' carry better, while being constant in training and so unsplittable anyway.
#'
#' It stays in the output as a diagnostic: it is the natural way to ask what share of
#' high-probability matches are cross-border.
#'
#' @param df the input dataframe
#'
#' @return a numeric predictor matrix
#'
make_X_matrix <- function(df) {
	df %>%
		mutate(
			# Occupation enters as TWO indicators, not one. A lone
			# grepl("Medical", ...) flag would fold missing and "Unknown" occupations
			# in with genuinely non-medical ones, because grepl() returns FALSE for
			# NA -- so a voter whose occupation is simply unrecorded would score as
			# evidence against a match, identically to one recorded as "Educator".
			# That distinction matters here because L2's commercial occupation data
			# is sparse, so "unknown" is a common and quite different state from
			# "known, and not medical".
			#
			# Computed from CommercialData_Occupation directly rather than reusing
			# the `medical` / `na_medical` columns that locality_sensitive_hash()
			# also derives, so this only depends on the raw field being present.
			occ_medical = grepl("Medical", CommercialData_Occupation, ignore.case = TRUE),
			occ_unknown = is.na(CommercialData_Occupation) | CommercialData_Occupation == "Unknown"
		) %>%
		select(zip_dist, year_dist, full_name_sim, mid_initial_agree, mid_name_agree, n,
					 occ_medical, occ_unknown) %>%
		# Coerce logicals to 0/1 rather than letting model.matrix expand them. Under
		# `~ -1 + .` a logical yields both a ...FALSE and a ...TRUE dummy, so
		# selecting 6 columns emitted a 7-column matrix with a perfectly
		# complementary, redundant pair.
		#
		# This is cosmetic, not a fix: logicals have a fixed {FALSE, TRUE} domain, so
		# the width was stable at 7 regardless of the data, and grf's default mtry is
		# min(ceiling(sqrt(p) + 20), p), which equals p at this size -- so the extra
		# column changed neither the column count across calls nor the feature
		# sampling. 6 columns for 6 features is simply easier to reason about.
		mutate(across(where(is.logical), as.integer)) %>%
		as.matrix()
}


#' Train the match model
#'
#' @description Fit a probability forest on the hand- and rule-labelled pairs. Trained
#' ONCE and reused for every year: the labelled data is 2018-only, so this assumes the
#' feature distribution is stable across the panel. That assumption is untested and
#' nothing here detects drift -- if match rates look odd in later years, check it first.
#'
#' @param labelled_training_files paths to the labelled training data
#'
#' @return a `grf::probability_forest` fit. Small enough to stay an in-memory target.
train_rf_model <- function(labelled_training_files) {
	labelled_training_data <- labelled_training_files %>%
		map(read_parquet) %>%
		list_rbind()

	probability_forest(make_X_matrix(labelled_training_data),
										 as.factor(labelled_training_data$match))
}


#' Score one year of candidate pairs
#'
#' @description Combines every state's candidate pairs for a year, computes `n`, and
#' predicts.
#'
#' `n` (candidates per NPI) is computed *here*, over both passes together, rather than in
#' either matching function. That is now load-bearing rather than merely forward-looking:
#' Stage B adds pairs for the same NPI out of adjacent states, so a per-branch count would
#' undercount and drift from the national definition the model was trained against.
#'
#' Scoring is per year rather than all at once because `grf` needs a materialised matrix,
#' and every candidate pair for eight years at national scale will not fit in memory. One
#' year is the scale the pipeline has historically handled.
#'
#' @param lsh_pairs paths to the Stage A (in-state) candidate pair datasets
#' @param cross_border_pairs paths to the Stage B (cross-border) datasets, possibly empty
#' @param rf_model fitted model from `train_rf_model()`
#' @param this_year the year this branch scores
#' @param out_pth glue template for the output directory
#'
#' @return `out_pth` -- the year's pairs with a `match_prob` column. Named `match_prob`,
#'   not `match`, so it cannot be confused with the training *label* column of that name.
score_pairs <- function(lsh_pairs, cross_border_pairs, rf_model, this_year,
												out_pth = "trunk/derived/scored_pairs/year={this_year}") {
	if (rlang::is_empty(lsh_pairs) && rlang::is_empty(cross_border_pairs)) {
		return(NULL)
	}

	out_pth <- glue::glue(out_pth)
	unlink(out_pth, recursive = TRUE)

	# Recover each pass's partitioned root from its branch paths so the hive year/state
	# columns come back; opening the leaf paths individually would lose them.
	roots <- c(
		if (rlang::is_empty(lsh_pairs)) NULL else unique(dirname(dirname(lsh_pairs))),
		if (rlang::is_empty(cross_border_pairs)) NULL else unique(dirname(dirname(cross_border_pairs)))
	)

	pairs <- roots %>%
		map(\(r) open_dataset(r) %>% filter(year == this_year) %>% collect()) %>%
		list_rbind()

	if (nrow(pairs) == 0) {
		return(NULL)
	}

	pairs <- pairs %>%
		group_by(npi) %>%
		mutate(n = n()) %>%
		ungroup()

	pairs$match_prob <- predict(rf_model, newdata = make_X_matrix(pairs))$predictions[,2]

	write_dataset(pairs, out_pth)

	return_out_pth_check_distinct(out_pth, distinct_col = c("npi", "LALVOTERID"))
}
