#' Make Predictor Matrix
#'
#' @description Extract the predictors used for a classification model, and format them as a
#' numeric matrix
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
#' `n` (candidates per NPI) is computed *here* rather than in
#' `locality_sensitive_hash()`. Today the two are equivalent: physicians are filtered to
#' their own practice state, so within a year an NPI appears in exactly one state branch.
#' It matters from Stage B onwards, when the cross-border pass starts adding pairs for the
#' same NPI out of *adjacent* states -- at which point a per-branch count would undercount
#' and drift from the national definition the model was trained against. Computing it here
#' is correct now and stays correct then.
#'
#' Scoring is per year rather than all at once because `grf` needs a materialised matrix,
#' and every candidate pair for eight years at national scale will not fit in memory. One
#' year is the scale the pipeline has historically handled.
#'
#' @param lsh_pairs paths to the per-state-year candidate pair datasets
#' @param rf_model fitted model from `train_rf_model()`
#' @param this_year the year this branch scores
#' @param out_pth glue template for the output directory
#'
#' @return `out_pth` -- the year's pairs with a `match_prob` column. Named `match_prob`,
#'   not `match`, so it cannot be confused with the training *label* column of that name.
score_pairs <- function(lsh_pairs, rf_model, this_year,
												out_pth = "trunk/derived/scored_pairs/year={this_year}") {
	if (rlang::is_empty(lsh_pairs)) {
		return(NULL)
	}

	out_pth <- glue::glue(out_pth)
	unlink(out_pth, recursive = TRUE)

	# Recover the partitioned root from the branch paths so the hive year/state columns
	# come back; opening the leaf paths individually would lose them.
	root <- unique(dirname(dirname(lsh_pairs)))

	pairs <- open_dataset(root) %>%
		filter(year == this_year) %>%
		collect()

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
