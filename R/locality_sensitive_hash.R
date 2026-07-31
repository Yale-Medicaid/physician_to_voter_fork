#' Create a datframe of possible match pairs using locality sensitive hashing
#' 
#' @param physician_data path to the cleaned physician dataset written by
#'   `clean_physician_data()`
#' @param voter_files a vector of cleaned voter files, as returned by `process_voter data`
#' @param zip_centroid_file path to the NBER ZCTA centroid csv (see
#'   `zip_centroid_file` in `_targets.R`)
#' @param out_pth directory to write the candidate pairs to
#'
#' @return `out_pth` -- a parquet dataset of 'rough matches' or possible matches, one row
#' per (npi, LALVOTERID) pair. This should have very high recall as it's basically a
#' blocking step; we should return all possible matching records, and expect a very high
#' false-positive rate
#'
locality_sensitive_hash <- function(physician_data, voter_files, zip_centroid_file,
																		out_pth = "trunk/derived/lshed_data") {
	if (rlang::is_empty(physician_data) || rlang::is_empty(voter_files)) {
		return(NULL)
	}

	unlink(out_pth, recursive = TRUE)

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
	
	combined_schema <- c(LALVOTERID  = "c", yale_schema, datavant_schema)
	
	# Standardize Physician Data
	# `coalesce()` rather than `replace_na()` throughout: arrow has no binding for
	# replace_na and silently pulls the whole table into R when it meets one.
	phys_data <- arrow::open_dataset(physician_data) %>%
		mutate(
			# coalesce the middle name, matching the voter side below. Unguarded,
			# paste0 renders a missing middle name as the literal string "NA" and
			# splices it into the name being compared.
			full_name = tolower(paste0(provider_first_name, coalesce(provider_middle_name, ""), `provider_last_name_(legal_name)`)),
			full_name_no_mid = tolower(paste0(provider_first_name, `provider_last_name_(legal_name)`)),
			st = tolower(coalesce(provider_business_mailing_address_state_name, "")),
			st_mi = tolower(paste0(coalesce(substr(provider_middle_name,1,1),""),st)),
			) %>%
		rename(
			zip = provider_business_mailing_address_postal_code,
			frst_nm = provider_first_name,
			mid_nm = provider_middle_name,
			last_nm = `provider_last_name_(legal_name)`
			) %>%
		collect()   # zoomerjoin needs materialised vectors


	# Collect relevant fields from voter files, format to be compatible with physician data.
	# The derived columns are computed inside the arrow query, before collect(), so
	# they are evaluated as the dataset streams rather than over the whole voter
	# file held in memory.
	voter_dataset <- open_dataset(voter_files)  %>%
		select(LALVOTERID, contains("Voters_"),
					 Residence_Addresses_Zip,Residence_Addresses_State,
					 Residence_Addresses_City, contains("Occupation"),
					 any_of(names(combined_schema))
					 ) %>%
		mutate(
			full_name = tolower(paste0(Voters_FirstName, coalesce(Voters_MiddleName, ""), Voters_LastName)),
			full_name_no_mid_l2 = tolower(paste0(Voters_FirstName, Voters_LastName)),
			st = coalesce(tolower(Residence_Addresses_State),""),
			st_mi = tolower(paste0(coalesce(substr(Voters_MiddleName,1,1),""),coalesce(Residence_Addresses_State,""))),
			medical = grepl("Medical", CommercialData_Occupation, ignore.case = T),
			na_medical = is.na(CommercialData_Occupation) | CommercialData_Occupation == "Unknown",
			medical_sub = ifelse(grepl("Medical", CommercialData_Occupation, ignore.case = T),CommercialData_Occupation, "None")
		) %>%
		collect()
	
	print("Cleaning Data Finished")
	print(Sys.time())
	
	
	# Perform LSH on full name blocking on state
	# NB: `block_by` takes a single column name present in both tables; the
	# c("a" = "b") renaming form errors in zoomerjoin (see block_by note below),
	# which is why the voter-side blocking columns are named to match the
	# physician side rather than carrying a _2 suffix. `by` must be given
	# explicitly -- it is not optional.
	join_out_1 <- jaccard_inner_join(phys_data, voter_dataset,
															 by = c("full_name" = "full_name"), block_by = "st",
														 n_gram_width=3, band_width = 7, n_bands = 400, threshold=.7, clean=T, progress=T)
	
	print("Finished First Join")
	print(Sys.time())
	
	# Perform LSH on first + last name blocking on state and middle initial
	join_out_2 <- jaccard_inner_join(phys_data, voter_dataset,
															 by = c("full_name_no_mid" = "full_name_no_mid_l2"), block_by = "st_mi",
														 n_gram_width=3, band_width = 7, n_bands = 400, threshold=.7, clean=T, progress=T) %>%
		# coalesce before nchar(): nchar(NA) is NA, NA <= 1 is NA, and filter() drops
		# NA rows -- so a pair with no middle name on *either* side evaluated to
		# NA | NA and was dropped, which is the opposite of this filter's intent.
		filter(nchar(coalesce(Voters_MiddleName, "")) <= 1 | nchar(coalesce(mid_nm, "")) <= 1)
		
	
	print("Finished Second Join")
	print(Sys.time())
	
	# clear voter dataset because I am about to concat two large tables in memory
	rm(voter_dataset)
	gc()
	
	# append two datasets
	
	join_out <- bind_rows(join_out_1, join_out_2) %>%
		distinct()
	
	print("Finished Joining")
	
	# standardize joined data
	processed <- join_out %>%
		mutate(
			Voters_MiddleName = replace_na(Voters_MiddleName, ""),
			mid_nm = replace_na(mid_nm, ""), 
			year_dist = grd_yr - year(Voters_BirthDate),
		) %>%
		group_by(npi) %>%
		mutate(n = n()) 
	
	# ZIP-to-ZIP distance, computed from the NBER ZCTA centroid file rather than
	# looked up in one of their pre-computed distance files.
	#
	# The centroid file is small (33,791 rows) and gives each ZCTA's Census
	# "internal point". NBER's distance files are great-circle distances between
	# exactly those points via the Haversine formula, so computing here reproduces
	# their published numbers -- validated to a maximum absolute error of 0.000035
	# miles over 20,000 pairs drawn from their own 25-mile file.
	#
	# Why compute rather than look up:
	#  1. No radius truncation. Every distance file is capped (100 miles, 500
	#     miles, ...), so any pair beyond the cap is simply absent from it. Here
	#     every pair gets a real distance however far apart.
	#  2. NA now means one thing only -- "not a valid ZCTA" -- rather than
	#     conflating that with "farther apart than the cap". Not every USPS ZIP has
	#     a ZCTA; PO-box-only ZIPs, for instance, have none. grf handles the
	#     remaining missingness natively.
	#  3. No same-ZIP special case. The distance files omit zip1 == zip2 pairs
	#     entirely and needed those filled in as 0; the formula simply returns 0.
	#  4. 890 KB of input instead of ~0.5 GB (100-mile) or ~10 GB (500-mile).
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

	# match() rather than a join: the centroid table is tiny but `processed` is not,
	# and this avoids materialising four extra lat/long columns alongside it. An
	# unmatched ZIP gives NA, which indexes to NA and propagates to NA distance.
	i_phys  <- match(substr(processed$zip, 1, 5),                     centroids$zcta5)
	i_voter <- match(substr(processed$Residence_Addresses_Zip, 1, 5), centroids$zcta5)

	zip_dist_vec <- haversine_miles(
		centroids$intptlat[i_phys],  centroids$intptlong[i_phys],
		centroids$intptlat[i_voter], centroids$intptlong[i_voter]
	)

	# create a second dataset of match statistics, then bind onto joined data
	comparison_dataset <-
		tibble(
			full_name_sim = jaccard_similarity(processed$full_name.x, processed$full_name.y, 3), 
			# both blocking columns are named `st`, so the join suffixes them
			state_agree = processed$st.x == processed$st.y,
			mid_initial_agree = tolower(substr(processed$mid_nm,1,1)) == tolower(substr(processed$Voters_MiddleName,1,1)),
			# 2-grams here, deliberately, where every other name comparison uses 3 --
			# middle names are short enough that 3-grams are too coarse. This was
			# previously jaccard_similarity()'s default rather than an explicit
			# choice; passed explicitly so it is not "corrected" later.
			mid_name_agree = jaccard_similarity(tolower(processed$mid_nm), tolower(processed$Voters_MiddleName), 2),
			phys_mid_name_len = nchar(processed$mid_nm),
			voters_mid_name_len = nchar(processed$Voters_MiddleName),
			zip_dist = zip_dist_vec
		)

		# ungroup(): `processed` is still grouped by npi from the n = n() step above, and a
		# grouped frame is a poor thing to hand to arrow or to a downstream consumer.
		bind_cols(comparison_dataset, processed) %>%
			ungroup() %>%
			write_dataset(out_pth)

	# One row per candidate pair. This holds only because physician_data is distinct in
	# npi -- a duplicated physician row would duplicate every pair it generates.
	return_out_pth_check_distinct(out_pth, distinct_col = c("npi", "LALVOTERID"))
}

