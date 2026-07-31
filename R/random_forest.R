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
		select(zip_dist, year_dist, full_name_sim, mid_initial_agree, mid_name_agree, n) %>%
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
#' @param lshed_data dataframe of potential matches created by LSH functions
#' @param labelled_training_files paths to the labelled training data
#'
#' @return The input dataframe, with an extra column given the probability that
#' each pair of records matches, as predicted by the random forest
#'
add_rf_match_predictions_to_df <- function(labelled_training_files, lshed_data){
	labelled_training_data <- labelled_training_files %>%
		map(read_parquet) %>%
		list_rbind()

	training_X <- make_X_matrix(labelled_training_data)
	training_Y <- as.factor(labelled_training_data$match)

	model <- probability_forest(training_X, training_Y)


	X <- make_X_matrix(lshed_data)
	lshed_data$match <- predict(model, newdata=X)$predictions[,2]

	return(lshed_data)
}



