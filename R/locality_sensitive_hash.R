#' L2 columns to carry through the match
#'
#' @description Legacy vectors from an earlier project, kept so other L2 analyses see the
#' same column set. Only the names are used; the "c"/"n" type codes are never applied.
#'
#' @return character vector of column names
l2_match_columns <- function() {
  yale_schema <- c(
    CommercialData_Occupation = "c",
    CommercialData_OccupationGroup = "c",
    CommercialData_OccupationIndustry = "c",
    County = "c",
    EthnicGroups_EthnicGroup1Desc = "c",
    Ethnic_Description = "c",
    FECDonors_AvgDonation = "n",
    FECDonors_AvgDonation_Range = "c",
    FECDonors_LastDonationDate = "c",
    FECDonors_NumberOfDonations = "n",
    FECDonors_PrimaryRecipientOfContributions = "c",
    FECDonors_TotalDonationsAmount = "n",
    FECDonors_TotalDonationsAmt_Range = "c",
    Parties_Description = "c",
    Residence_Addresses_CensusTract = "c",
    Voters_Age = "n",
    Voters_BirthDate = "c",
    Voters_Gender = "c"
  )

  datavant_schema <- c(
    Residence_Addresses_State = "c",
    Residence_Addresses_Zip = "c",
    Residence_Addresses_ZipPlus4 = "c",
    CommercialData_Education = "c",
    CommercialData_EstHomeValue = "c",
    CommercialData_HomePurchasePrice = "c",
    CommercialData_EstimatedHHIncome = "c",
    Voters_Age = "n",
    Voters_BirthDate = "c",
    Voters_FirstName = "c",
    Voters_Gender = "c",
    Voters_LastName = "c",
    Voters_MiddleName = "c",
    Voters_NameSuffix = "c"
  )

  names(c(LALVOTERID = "c", yale_schema, datavant_schema))
}


#' Derive the physician-side match columns
#'
#' @description `coalesce()` rather than `replace_na()` throughout: arrow has no binding for
#' `replace_na` and silently pulls the whole table into R when it meets one.
#'
#' @param phys a collected physician frame
#'
#' @return the frame with match columns added and the long NPPES names shortened
prepare_physicians <- function(phys) {
  phys |>
    dplyr::mutate(
      full_name = tolower(paste0(provider_first_name,
                                 dplyr::coalesce(provider_middle_name, ""),
                                 provider_last_name)),
      full_name_no_mid = tolower(paste0(provider_first_name, provider_last_name)),
      st = tolower(dplyr::coalesce(state, "")),
      mi = tolower(dplyr::coalesce(substr(provider_middle_name, 1, 1), ""))
    ) |>
    dplyr::rename(
      frst_nm = provider_first_name,
      mid_nm = provider_middle_name,
      last_nm = provider_last_name
    )
}


#' Read one L2 extract and derive the voter-side match columns
#'
#' @description Reads exactly one `month=/day=` leaf; opening higher would union several
#' extract dates. The occupation column is canonicalised here because it was renamed between
#' 2024 and 2025 -- without that, a 2025 read would come out empty rather than erroring. The
#' derived columns sit before `collect()` so they evaluate as the dataset streams.
#'
#' @param l2_extract path to one resolved L2 leaf
#'
#' @return a collected voter frame with match columns added
read_l2_partition <- function(l2_extract) {
  occ_col <- l2_occupation_col(get_l2_year(l2_extract))

  arrow::open_dataset(l2_extract) |>
    dplyr::select(LALVOTERID, dplyr::contains("Voters_"),
                  Residence_Addresses_Zip, Residence_Addresses_State,
                  Residence_Addresses_City, dplyr::contains("Occupation"),
                  dplyr::any_of(l2_match_columns())) |>
    dplyr::rename(CommercialData_Occupation = dplyr::any_of(occ_col)) |>
    dplyr::mutate(
      full_name = tolower(paste0(Voters_FirstName,
                                 dplyr::coalesce(Voters_MiddleName, ""),
                                 Voters_LastName)),
      full_name_no_mid_l2 = tolower(paste0(Voters_FirstName, Voters_LastName)),
      st = dplyr::coalesce(tolower(Residence_Addresses_State), ""),
      mi = tolower(dplyr::coalesce(substr(Voters_MiddleName, 1, 1), "")),
      medical = grepl("Medical", CommercialData_Occupation, ignore.case = TRUE),
      na_medical = is.na(CommercialData_Occupation) |
        CommercialData_Occupation == "Unknown",
      medical_sub = ifelse(grepl("Medical", CommercialData_Occupation,
                                 ignore.case = TRUE),
                           CommercialData_Occupation, "None")
    ) |>
    dplyr::collect()
}


#' Match a physician frame against a voter frame and build the comparison features
#'
#' @description The shared core of both matching passes: two LSH joins, unioned, plus the
#' per-pair comparison features.
#'
#' Note `n` (candidates per NPI) is deliberately NOT computed here; `score_pairs()` does,
#' after a year's states are combined. See its docs for why.
#'
#' @param phys_data physician frame from `prepare_physicians()`
#' @param voter_dataset voter frame from `read_l2_partition()`
#' @param zip_centroid_file path to the NBER ZCTA centroid csv
#' @param n_gram_width,band_width,n_bands,threshold zoomerjoin LSH tuning
#' @param nthread Rayon threads per call. `NULL` uses Rayon's global pool, i.e. every
#'   logical core -- which oversubscribes badly once several crew workers each do it.
#'
#' @return a frame of candidate pairs with comparison features, or `NULL` if either side is
#'   empty or no pairs were found
match_pairs <- function(phys_data, voter_dataset, zip_centroid_file,
                        n_gram_width = 3, band_width = 7,
                        n_bands = 400, threshold = 0.7, nthread = NULL) {
  if (nrow(phys_data) == 0 || nrow(voter_dataset) == 0) {
    return(NULL)
  }

  # no block_by: the caller has scoped this to one partition. `by` is still required --
  # omitting it errors with "'by_a' must be of length 1" on CRAN zoomerjoin.
  join_out_1 <- zoomerjoin::jaccard_inner_join(phys_data, voter_dataset,
                                               by = c("full_name" = "full_name"),
                                               n_gram_width = n_gram_width,
                                               band_width = band_width,
                                               n_bands = n_bands,
                                               threshold = threshold,
                                               nthread = nthread,
                                               clean = TRUE, progress = TRUE)

  # block_by = "mi" carries the middle-initial *agreement* requirement. Dropping it would
  # match first+last across all middle initials; the post-filter below is not a substitute.
  join_out_2 <- zoomerjoin::jaccard_inner_join(phys_data, voter_dataset,
                                               by = c("full_name_no_mid" =
                                                        "full_name_no_mid_l2"),
                                               block_by = "mi",
                                               n_gram_width = n_gram_width,
                                               band_width = band_width,
                                               n_bands = n_bands,
                                               threshold = threshold,
                                               nthread = nthread,
                                               clean = TRUE, progress = TRUE) |>
    # coalesce before nchar(): nchar(NA) is NA, and filter() drops NA rows
    dplyr::filter(nchar(dplyr::coalesce(Voters_MiddleName, "")) <= 1 |
                    nchar(dplyr::coalesce(mid_nm, "")) <= 1)

  join_out <- dplyr::bind_rows(join_out_1, join_out_2) |>
    dplyr::distinct()

  if (nrow(join_out) == 0) {
    return(NULL)
  }

  processed <- join_out |>
    dplyr::mutate(
      Voters_MiddleName = dplyr::coalesce(Voters_MiddleName, ""),
      mid_nm = dplyr::coalesce(mid_nm, ""),
      year_dist = grd_yr - lubridate::year(Voters_BirthDate)
    )

  EARTH_RADIUS_MILES <- 6371/1.609344   # 6371 km -- the radius NBER's files match

  centroids <- arrow::open_dataset(zip_centroid_file,
                                   format = "csv",
                                   # ZCTA must be a string; inference strips leading zeros
                                   schema = arrow::schema(zcta5 = arrow::string(),
                                                          intptlat = arrow::float64(),
                                                          intptlong = arrow::float64()),
                                   skip = 1) |>
    dplyr::collect()

  haversine_miles <- function(lat1, lon1, lat2, lon2) {
    rad <- pi/180
    a <- sin((lat2 - lat1)*rad/2)^2 +
      cos(lat1*rad)*cos(lat2*rad)*sin((lon2 - lon1)*rad/2)^2
    # clamp: floating point can nudge `a` above 1
    2*EARTH_RADIUS_MILES*asin(sqrt(pmin(1, a)))
  }

  i_phys <- match(substr(processed$zip, 1, 5), centroids$zcta5)
  i_voter <- match(substr(processed$Residence_Addresses_Zip, 1, 5), centroids$zcta5)

  zip_dist_vec <- haversine_miles(centroids$intptlat[i_phys],
                                  centroids$intptlong[i_phys],
                                  centroids$intptlat[i_voter],
                                  centroids$intptlong[i_voter])

  comparison_dataset <-
    tibble::tibble(
      full_name_sim = zoomerjoin::jaccard_similarity(processed$full_name.x,
                                                     processed$full_name.y,
                                                     n_gram_width),
      state_agree = processed$st.x == processed$st.y,
      mid_initial_agree = tolower(substr(processed$mid_nm, 1, 1)) ==
        tolower(substr(processed$Voters_MiddleName, 1, 1)),
      # 2-grams deliberately, not n_gram_width -- do not "correct" this
      mid_name_agree = zoomerjoin::jaccard_similarity(tolower(processed$mid_nm),
                                                      tolower(processed$Voters_MiddleName),
                                                      2),
      phys_mid_name_len = nchar(processed$mid_nm),
      voters_mid_name_len = nchar(processed$Voters_MiddleName),
      zip_dist = zip_dist_vec
    )

  dplyr::bind_cols(comparison_dataset, processed)
}


#' Stage A -- match physicians against the voter file of their own state
#'
#' @param physician_data path to the cleaned physician dataset
#' @param l2_extract path to ONE resolved L2 leaf, or `NULL` for an absent state-year
#' @param zip_centroid_file path to the NBER ZCTA centroid csv
#' @param out_pth glue template for the output directory
#' @param n_gram_width,band_width,n_bands,threshold zoomerjoin LSH tuning
#' @param nthread Rayon threads per call. `NULL` uses Rayon's global pool, i.e. every
#'   logical core -- which oversubscribes badly once several crew workers each do it.
#'
#' @return `out_pth` -- candidate pairs for this state-year, one row per
#'   (npi, LALVOTERID), or `NULL`
locality_sensitive_hash <- function(physician_data, l2_extract, zip_centroid_file,
                                    out_pth = "trunk/derived/lsh_pairs/{ys}",
                                    n_gram_width = 3, band_width = 7,
                                    n_bands = 400, threshold = 0.7,
                                    nthread = NULL) {
  if (rlang::is_empty(physician_data) || rlang::is_empty(l2_extract)) {
    return(NULL)
  }

  this_state <- get_l2_state(l2_extract)
  this_year <- get_l2_year(l2_extract)
  ys <- build_l2_out_subdir(l2_extract)
  out_pth <- glue::glue(out_pth)

  unlink(out_pth, recursive = TRUE)

  phys_data <- arrow::open_dataset(unique(dirname(physician_data))) |>
    dplyr::filter(year == !!this_year, state == !!this_state) |>
    dplyr::collect() |>
    prepare_physicians()

  pairs <- match_pairs(phys_data, read_l2_partition(l2_extract), zip_centroid_file,
                       n_gram_width, band_width, n_bands, threshold, nthread)

  if (rlang::is_empty(pairs)) {
    return(NULL)
  }

  arrow::write_dataset(pairs, out_pth)

  return_out_pth_check_distinct(out_pth, distinct_col = c("npi", "LALVOTERID"))
}


#' Stage B -- match leftover physicians against neighbouring states' voter files
#'
#' @description Catches physicians who practise in one state and live in another; only those
#' without a unique strong in-state match are retried. Adjacent partitions are resolved from
#' `l2_path` rather than the `l2_extracts` target, because a dynamic branch cannot reach its
#' siblings.
#'
#' @param physician_data path to the cleaned physician dataset
#' @param l2_extract this branch's own L2 leaf, used only to learn its state and year
#' @param lsh_pairs paths to the Stage A outputs, to work out who is still unmatched
#' @param l2_path glue template for the L2 root
#' @param zip_centroid_file path to the NBER ZCTA centroid csv
#' @param out_pth glue template for the output directory
#' @param min_name_sim passed to `unmatched_physicians()`
#' @param n_gram_width,band_width,n_bands,threshold zoomerjoin LSH tuning
#' @param nthread Rayon threads per call. `NULL` uses Rayon's global pool, i.e. every
#'   logical core -- which oversubscribes badly once several crew workers each do it.
#'
#' @return `out_pth` -- cross-border candidate pairs, or `NULL` if there were none.
#'   Partitioned by the *physician's* state-year, not the voter's, so all of a physician's
#'   pairs stay in one place.
lsh_cross_border <- function(physician_data, l2_extract, lsh_pairs, l2_path,
                             zip_centroid_file,
                             out_pth = "trunk/derived/cross_border_pairs/{ys}",
                             min_name_sim = 0.85,
                             n_gram_width = 3, band_width = 7,
                             n_bands = 400, threshold = 0.7,
                             nthread = NULL) {
  if (rlang::is_empty(physician_data) || rlang::is_empty(l2_extract)) {
    return(NULL)
  }

  this_state <- get_l2_state(l2_extract)
  this_year <- get_l2_year(l2_extract)
  neighbours <- adjacent_states(this_state)

  if (rlang::is_empty(neighbours)) {
    return(NULL)
  }

  leftover <- unmatched_physicians(physician_data, lsh_pairs, this_state, this_year,
                                   min_name_sim = min_name_sim)

  if (rlang::is_empty(leftover)) {
    return(NULL)
  }

  phys_data <- prepare_physicians(leftover)

  pairs <- neighbours |>
    purrr::map(\(nb) {
      nb_extract <- resolve_l2_extract(nb, this_year, l2_path)

      if (rlang::is_empty(nb_extract)) {
        return(NULL)
      }

      match_pairs(phys_data, read_l2_partition(nb_extract), zip_centroid_file,
                  n_gram_width, band_width, n_bands, threshold, nthread)
    }) |>
    purrr::compact() |>
    purrr::list_rbind()

  if (rlang::is_empty(pairs) || nrow(pairs) == 0) {
    return(NULL)
  }

  ys <- build_l2_out_subdir(l2_extract)
  out_pth <- glue::glue(out_pth)

  unlink(out_pth, recursive = TRUE)
  arrow::write_dataset(pairs, out_pth)

  return_out_pth_check_distinct(out_pth, distinct_col = c("npi", "LALVOTERID"))
}
