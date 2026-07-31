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


#' Add Random Forest Matching Predictions to the LSH dataframe
#'
#' @description Fit a Random Forest model to predict whether pairs of records
#' match based on labelled training data. Use this Random Forest to predict
#' whether pairs of records given by LSH are matches.
#'
#' @param lshed_data path to the parquet dataset of potential matches written by
#'   `locality_sensitive_hash()`
#' @param labelled_training_files paths to the labelled training data
#' @param out_pth directory to write the scored dataset to
#'
#' @return `out_pth` -- the input pairs with an extra `match` column giving the
#'   probability that each pair matches, as predicted by the random forest
#'
add_rf_match_predictions_to_df <- function(labelled_training_files, lshed_data,
																					 out_pth = "trunk/derived/rf_match_data"){
	if (rlang::is_empty(lshed_data)) {
		return(NULL)
	}

	labelled_training_data <- labelled_training_files %>%
		map(read_parquet) %>%
		list_rbind()

	training_X <- make_X_matrix(labelled_training_data)
	training_Y <- as.factor(labelled_training_data$match)

	model <- probability_forest(training_X, training_Y)

	# grf needs a materialised matrix, so the candidate pairs come into memory here
	# regardless; the path-passing is about what crosses the target boundary.
	pairs <- arrow::open_dataset(lshed_data) %>%
		collect()

	X <- make_X_matrix(pairs)
	pairs$match <- predict(model, newdata=X)$predictions[,2]

	write_and_return(pairs, out_pth)
}



