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
  df |>
    dplyr::mutate(
      occ_medical = grepl("Medical", CommercialData_Occupation, ignore.case = TRUE),
      occ_unknown = is.na(CommercialData_Occupation) | CommercialData_Occupation == "Unknown"
    ) |>
    dplyr::select(zip_dist, year_dist, full_name_sim, mid_initial_agree,
                  mid_name_agree, n, occ_medical, occ_unknown) |>
    dplyr::mutate(dplyr::across(where(is.logical), as.integer)) |>
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
  labelled_training_data <- labelled_training_files |>
    purrr::map(read_parquet) |>
    purrr::list_rbind()

  grf::probability_forest(make_X_matrix(labelled_training_data),
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
    dplyr::mutate(n = n()) |>
    dplyr::ungroup()

  pairs$match_prob <- predict(rf_model, newdata = make_X_matrix(pairs))$predictions[, 2]

  # out_pth is itself a `year=` hive directory, so keeping the column would make a re-read
  # see `year` from two sources, which arrow refuses to merge on any type mismatch
  pairs |>
    dplyr::select(-dplyr::any_of("year")) |>
    arrow::write_dataset(out_pth)

  return_out_pth_check_distinct(out_pth, distinct_col = c("npi", "LALVOTERID"))
}
