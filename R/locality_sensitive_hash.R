#' L2 columns to carry through the match
#'
#' @description Legacy `yale_schema` / `datavant_schema` vectors from an earlier project,
#' kept because other L2 analyses expect the same column set. Only the *names* are used
#' here -- the "c"/"n" type codes are never applied.
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
		Residence_Addresses_CensusTract	= "c",
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
#' @description `coalesce()` rather than `replace_na()` throughout, matching the voter
#' side: arrow has no binding for `replace_na` and silently pulls the whole table into R
#' when it meets one.
#'
#' @param phys a collected physician frame
#'
#' @return the frame with match columns added and the long NPPES names shortened
prepare_physicians <- function(phys) {
	phys %>%
		mutate(
			# coalesce the middle name, matching the voter side. Unguarded, paste0 renders a
			# missing middle name as the literal string "NA" and splices it into the name
			# being compared, pushing otherwise-perfect matches below the LSH threshold.
			full_name = tolower(paste0(provider_first_name, coalesce(provider_middle_name, ""), `provider_last_name_(legal_name)`)),
			full_name_no_mid = tolower(paste0(provider_first_name, `provider_last_name_(legal_name)`)),
			st = tolower(coalesce(provider_business_mailing_address_state_name, "")),
			# middle initial alone; state is handled by the partition
			mi = tolower(coalesce(substr(provider_middle_name, 1, 1), ""))
		) %>%
		rename(
			zip = provider_business_mailing_address_postal_code,
			frst_nm = provider_first_name,
			mid_nm = provider_middle_name,
			last_nm = `provider_last_name_(legal_name)`
		)
}


#' Read one L2 extract and derive the voter-side match columns
#'
#' @description Reads exactly one `month=/day=` leaf, never the `state=/year=` level --
#' opening higher would silently union several extract dates together.
#'
#' The occupation column is renamed between 2024 and 2025, so it is canonicalised to
#' `CommercialData_Occupation` here. This matters: without it the 2025 read would not
#' *error*, because `contains("Occupation")` and `any_of()` would quietly match nothing and
#' every occupation-derived column would come out empty.
#'
#' The derived columns are computed inside the arrow query, before `collect()`, so they
#' evaluate as the dataset streams rather than over the whole partition held in memory.
#'
#' @param l2_extract path to one resolved L2 leaf
#'
#' @return a collected voter frame with match columns added
read_l2_partition <- function(l2_extract) {
	occ_col <- l2_occupation_col(get_l2_year(l2_extract))

	open_dataset(l2_extract) %>%
		select(LALVOTERID, contains("Voters_"),
					 Residence_Addresses_Zip, Residence_Addresses_State,
					 Residence_Addresses_City, contains("Occupation"),
					 any_of(l2_match_columns())
					 ) %>%
		rename(CommercialData_Occupation = any_of(occ_col)) %>%
		mutate(
			full_name = tolower(paste0(Voters_FirstName, coalesce(Voters_MiddleName, ""), Voters_LastName)),
			full_name_no_mid_l2 = tolower(paste0(Voters_FirstName, Voters_LastName)),
			st = coalesce(tolower(Residence_Addresses_State), ""),
			mi = tolower(coalesce(substr(Voters_MiddleName, 1, 1), "")),
			medical = grepl("Medical", CommercialData_Occupation, ignore.case = T),
			na_medical = is.na(CommercialData_Occupation) | CommercialData_Occupation == "Unknown",
			medical_sub = ifelse(grepl("Medical", CommercialData_Occupation, ignore.case = T), CommercialData_Occupation, "None")
		) %>%
		collect()
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
#'
#' @return a frame of candidate pairs with comparison features, or `NULL` if either side is
#'   empty or no pairs were found
match_pairs <- function(phys_data, voter_dataset, zip_centroid_file,
												n_gram_width = 3, band_width = 7,
												n_bands = 400, threshold = 0.7) {
	if (nrow(phys_data) == 0 || nrow(voter_dataset) == 0) {
		return(NULL)
	}

	# Full name, no blocking -- the caller has already scoped this to a single partition,
	# so state blocking would be redundant. `by` is still required though: omitting it
	# errors with "'by_a' must be of length 1" on CRAN zoomerjoin.
	join_out_1 <- jaccard_inner_join(phys_data, voter_dataset,
																	 by = c("full_name" = "full_name"),
																	 n_gram_width = n_gram_width, band_width = band_width,
																	 n_bands = n_bands, threshold = threshold, clean = T, progress = T)

	# First + last name, blocked on middle initial. Blocking is still needed here even
	# though state is handled by the partition: this join previously blocked on `st_mi`
	# (state AND initial), so dropping block_by outright would also drop the
	# middle-initial *agreement* requirement and start matching first+last across all
	# middle initials. The post-filter below does not substitute for that -- it tests
	# middle-name length, not agreement.
	join_out_2 <- jaccard_inner_join(phys_data, voter_dataset,
																	 by = c("full_name_no_mid" = "full_name_no_mid_l2"), block_by = "mi",
																	 n_gram_width = n_gram_width, band_width = band_width,
																	 n_bands = n_bands, threshold = threshold, clean = T, progress = T) %>%
		# coalesce before nchar(): nchar(NA) is NA, NA <= 1 is NA, and filter() drops NA
		# rows -- so a pair with no middle name on *either* side evaluated to NA | NA and
		# was dropped, the opposite of this filter's intent.
		filter(nchar(coalesce(Voters_MiddleName, "")) <= 1 | nchar(coalesce(mid_nm, "")) <= 1)

	join_out <- bind_rows(join_out_1, join_out_2) %>%
		distinct()

	if (nrow(join_out) == 0) {
		return(NULL)
	}

	processed <- join_out %>%
		mutate(
			Voters_MiddleName = replace_na(Voters_MiddleName, ""),
			mid_nm = replace_na(mid_nm, ""),
			year_dist = grd_yr - year(Voters_BirthDate)
		)

	# ZIP-to-ZIP distance, computed from the NBER ZCTA centroid file rather than looked up
	# in one of their pre-computed distance files.
	#
	# NBER's distance files are great-circle distances between exactly these Census
	# internal points, so computing here reproduces their published numbers -- validated to
	# a maximum absolute error of 0.000035 miles over 50,000 pairs from their 25-mile file.
	#
	# Why compute rather than look up:
	#  1. No radius truncation. Every published distance file is capped, so pairs beyond
	#     the cap are simply absent. Here every pair gets a real distance.
	#  2. NA means one thing only -- "not a valid ZCTA". PO-box-only ZIPs have none.
	#  3. No same-ZIP special case; the formula returns 0 for identical points.
	#  4. 890 KB of input instead of ~0.5 GB or ~10 GB.
	EARTH_RADIUS_MILES <- 6371 / 1.609344   # 6371 km -- the radius NBER's files match

	centroids <- arrow::open_dataset(
			zip_centroid_file,
			format = "csv",
			# read the ZCTA as a string; inferred types would strip leading zeros
			schema = arrow::schema(
				zcta5 = arrow::string(),
				intptlat = arrow::float64(),
				intptlong = arrow::float64()
			),
			skip = 1
		) %>%
		collect()

	haversine_miles <- function(lat1, lon1, lat2, lon2) {
		rad <- pi / 180
		a <- sin((lat2 - lat1) * rad / 2)^2 +
			cos(lat1 * rad) * cos(lat2 * rad) * sin((lon2 - lon1) * rad / 2)^2
		# clamp before asin(): floating point can nudge `a` a hair above 1
		2 * EARTH_RADIUS_MILES * asin(sqrt(pmin(1, a)))
	}

	# match() rather than a join: the centroid table is tiny but `processed` is not, and
	# this avoids materialising four extra lat/long columns alongside it. An unmatched ZIP
	# gives NA, which indexes to NA and propagates to NA distance.
	i_phys  <- match(substr(processed$zip, 1, 5),                     centroids$zcta5)
	i_voter <- match(substr(processed$Residence_Addresses_Zip, 1, 5), centroids$zcta5)

	zip_dist_vec <- haversine_miles(
		centroids$intptlat[i_phys],  centroids$intptlong[i_phys],
		centroids$intptlat[i_voter], centroids$intptlong[i_voter]
	)

	comparison_dataset <-
		tibble(
			# same n-gram width as the join that admitted the pair -- otherwise the gate
			# would cut on one quantity and the model would score a different one
			full_name_sim = jaccard_similarity(processed$full_name.x, processed$full_name.y, n_gram_width),
			# both sides carry `st`, so the join suffixes them. Constant TRUE for the
			# in-state pass; informative only once cross-border pairs exist.
			state_agree = processed$st.x == processed$st.y,
			mid_initial_agree = tolower(substr(processed$mid_nm, 1, 1)) == tolower(substr(processed$Voters_MiddleName, 1, 1)),
			# 2-grams here, deliberately, where every other name comparison uses
			# n_gram_width -- middle names are short enough that 3-grams are too coarse.
			# Confirmed intentional; do not "correct" it to follow n_gram_width.
			mid_name_agree = jaccard_similarity(tolower(processed$mid_nm), tolower(processed$Voters_MiddleName), 2),
			phys_mid_name_len = nchar(processed$mid_nm),
			voters_mid_name_len = nchar(processed$Voters_MiddleName),
			zip_dist = zip_dist_vec
		)

	bind_cols(comparison_dataset, processed)
}


#' Stage A -- match physicians against the voter file of their own state
#'
#' @param physician_data path to the cleaned physician dataset
#' @param l2_extract path to ONE resolved L2 leaf, or `NULL` for an absent state-year
#' @param zip_centroid_file path to the NBER ZCTA centroid csv
#' @param out_pth glue template for the output directory
#' @param n_gram_width,band_width,n_bands,threshold zoomerjoin LSH tuning
#'
#' @return `out_pth` -- candidate pairs for this state-year, one row per
#'   (npi, LALVOTERID), or `NULL`
locality_sensitive_hash <- function(physician_data, l2_extract, zip_centroid_file,
																		out_pth = "trunk/derived/lsh_pairs/{ys}",
																		n_gram_width = 3, band_width = 7,
																		n_bands = 400, threshold = 0.7) {
	if (rlang::is_empty(physician_data) || rlang::is_empty(l2_extract)) {
		return(NULL)
	}

	this_state <- get_l2_state(l2_extract)
	ys         <- build_l2_out_subdir(l2_extract)
	out_pth    <- glue::glue(out_pth)

	unlink(out_pth, recursive = TRUE)

	phys_data <- arrow::open_dataset(physician_data) %>%
		filter(tolower(provider_business_mailing_address_state_name) == tolower(this_state)) %>%
		collect() %>%
		prepare_physicians()

	pairs <- match_pairs(phys_data, read_l2_partition(l2_extract), zip_centroid_file,
											 n_gram_width, band_width, n_bands, threshold)

	if (rlang::is_empty(pairs)) {
		return(NULL)
	}

	write_dataset(pairs, out_pth)

	# One row per candidate pair. Holds only because physician_data is distinct in npi --
	# a duplicated physician row would duplicate every pair it generates.
	return_out_pth_check_distinct(out_pth, distinct_col = c("npi", "LALVOTERID"))
}


#' Stage B -- match leftover physicians against neighbouring states' voter files
#'
#' @description Catches physicians who practise in one state and live in another. Only
#' physicians without a unique strong in-state match are retried -- see
#' `unmatched_physicians()`.
#'
#' Adjacent partitions are resolved directly from `l2_path` rather than read off the
#' `l2_extracts` target, because a dynamic branch cannot reach its siblings.
#'
#' @param physician_data path to the cleaned physician dataset
#' @param l2_extract this branch's own L2 leaf, used only to learn its state and year
#' @param lsh_pairs paths to the Stage A outputs, to work out who is still unmatched
#' @param l2_path glue template for the L2 root
#' @param zip_centroid_file path to the NBER ZCTA centroid csv
#' @param out_pth glue template for the output directory
#' @param min_name_sim passed to `unmatched_physicians()`
#' @param n_gram_width,band_width,n_bands,threshold zoomerjoin LSH tuning
#'
#' @return `out_pth` -- cross-border candidate pairs, or `NULL` if there were none.
#'   Partitioned by the *physician's* state-year, not the voter's, so all of a physician's
#'   pairs stay in one place.
lsh_cross_border <- function(physician_data, l2_extract, lsh_pairs, l2_path,
														 zip_centroid_file,
														 out_pth = "trunk/derived/cross_border_pairs/{ys}",
														 min_name_sim = 0.85,
														 n_gram_width = 3, band_width = 7,
														 n_bands = 400, threshold = 0.7) {
	if (rlang::is_empty(physician_data) || rlang::is_empty(l2_extract)) {
		return(NULL)
	}

	this_state <- get_l2_state(l2_extract)
	this_year  <- get_l2_year(l2_extract)
	neighbours <- adjacent_states(this_state)

	# AK and HI have no land neighbours
	if (rlang::is_empty(neighbours)) {
		return(NULL)
	}

	leftover <- unmatched_physicians(physician_data, lsh_pairs, this_state, this_year,
																	 min_name_sim = min_name_sim)

	if (rlang::is_empty(leftover)) {
		return(NULL)
	}

	phys_data <- prepare_physicians(leftover)

	pairs <- neighbours %>%
		map(\(nb) {
			nb_extract <- resolve_l2_extract(nb, this_year, l2_path)

			# a neighbour may have no data for this year (2024 MD/MS/NV)
			if (rlang::is_empty(nb_extract)) {
				return(NULL)
			}

			match_pairs(phys_data, read_l2_partition(nb_extract), zip_centroid_file,
									n_gram_width, band_width, n_bands, threshold)
		}) %>%
		compact() %>%
		list_rbind()

	if (rlang::is_empty(pairs) || nrow(pairs) == 0) {
		return(NULL)
	}

	ys      <- build_l2_out_subdir(l2_extract)
	out_pth <- glue::glue(out_pth)

	unlink(out_pth, recursive = TRUE)
	write_dataset(pairs, out_pth)

	# A physician can legitimately match voters in several neighbouring states, so the
	# invariant is one row per (npi, LALVOTERID) pair, not one row per npi.
	return_out_pth_check_distinct(out_pth, distinct_col = c("npi", "LALVOTERID"))
}
