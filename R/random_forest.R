#' Make Predictor Matrix
#'
#' @description The eight predictors, as a numeric matrix. `state_agree` is deliberately
#' **not** among them -- distance is what makes a match implausible, and `zip_dist` measures
#' it directly and continuously. It stays in the output as a diagnostic. See CLAUDE.md.
#'
#' @param df the input dataframe
#'
#' @return a numeric predictor matrix
#'
make_X_matrix <- function(df) {
  df |>
    dplyr::mutate(
      occ_medical = grepl("Medical", CommercialData_Occupation, ignore.case = TRUE),
      occ_unknown = is.na(CommercialData_Occupation) | CommercialData_Occupation == "Unknown"
    ) |>
    dplyr::select(zip_dist, year_dist, full_name_sim, mid_initial_agree,
                  mid_name_agree, n, occ_medical, occ_unknown) |>
    dplyr::mutate(dplyr::across(tidyselect::where(is.logical), as.integer)) |>
    as.matrix()
}


#' Train the match model
#'
#' @description Fit once on the 2018 labels and reused for every year, which assumes the
#' feature distribution is stable across the panel. That assumption is untested and nothing
#' detects drift -- if later years look odd, check it first.
#'
#' @param labelled_training_files paths to the labelled training data
#'
#' @return a `grf::probability_forest` fit. Small enough to stay an in-memory target.
train_rf_model <- function(labelled_training_files) {
  labelled_training_data <- labelled_training_files |>
    purrr::map(arrow::read_parquet) |>
    purrr::list_rbind()

  grf::probability_forest(make_X_matrix(labelled_training_data),
                          as.factor(labelled_training_data$match))
}


#' Score one year of candidate pairs
#'
#' @description Combines both passes for a year, computes `n`, and predicts. `n` is computed
#' here rather than in either matching function because Stage B adds pairs for the same NPI
#' from adjacent states, so a per-branch count would undercount. Per year because `grf` needs
#' a materialised matrix.
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

  roots <- c(
    if (rlang::is_empty(lsh_pairs)) NULL else unique(dirname(dirname(lsh_pairs))),
    if (rlang::is_empty(cross_border_pairs)) NULL else unique(dirname(dirname(cross_border_pairs)))
  )

  pairs <- roots |>
    purrr::map(\(r) arrow::open_dataset(r) |>
                 dplyr::filter(year == this_year) |>
                 dplyr::collect()) |>
    purrr::list_rbind()

  if (nrow(pairs) == 0) {
    return(NULL)
  }

  pairs <- pairs |>
    dplyr::group_by(npi) |>
    dplyr::mutate(n = dplyr::n()) |>
    dplyr::ungroup()

  pairs$match_prob <- predict(rf_model, newdata = make_X_matrix(pairs))$predictions[, 2]

  # out_pth is itself a `year=` hive directory, so keeping the column would make a re-read
  # see `year` from two sources, which arrow refuses to merge on any type mismatch
  pairs |>
    dplyr::select(-dplyr::any_of("year")) |>
    arrow::write_dataset(out_pth)

  return_out_pth_check_distinct(out_pth, distinct_col = c("npi", "LALVOTERID"))
}
