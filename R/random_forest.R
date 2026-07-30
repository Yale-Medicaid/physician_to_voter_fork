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
	df <- df %>%
		mutate(med_prof = grepl("Medical", CommercialData_Occupation)) %>%
		select(zip_dist, year_dist, full_name_sim, mid_initial_agree, mid_name_agree, n)

	 model.matrix.lm(~-1 + ., df, na.action=na.pass)
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
		map_df(read_parquet)

	training_X <- make_X_matrix(labelled_training_data)
	training_Y <- as.factor(labelled_training_data$match)

	model <- probability_forest(training_X, training_Y)


	X <- make_X_matrix(lshed_data)
	lshed_data$match <- predict(model, newdata=X)$predictions[,2]

	return(lshed_data)
}



