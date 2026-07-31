#' Create a datframe of possible match pairs using locality sensitive hashing
#' 
#' @param physican_data dataframe of cleaned physican data, as returned by `clean_physician_data`
#' @param voter_files a vector of cleaned voter files, as returned by `process_voter data`
#' @param zip_distance_file path to the NBER ZCTA-to-ZCTA distance csv (see
#'   `zip_distance_file` in `_targets.R`)
#'
#' @return a dataframe of 'rough matches' or possible matches. This should have
#' very high recall as it's basically a blocking step; we should return all
#' possible matching records, and expect a very high false-positive rate
#'
locality_sensitive_hash <- function(physician_data, voter_files, zip_distance_file) {
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
	phys_data <- arrow::as_arrow_table(physician_data) %>%
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
		filter(nchar(Voters_MiddleName)<=1 | nchar(mid_nm) <= 1)
		
	
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
	
	# ZIP-to-ZIP distance, from the NBER ZCTA distance database.
	#
	# Three properties of that file drive the shape of this code:
	#  1. It omits same-ZIP pairs entirely, so `zip1 == zip2` never matches and has
	#     to be filled in as 0. Left as NA it would turn the strongest co-location
	#     signal we have into a missing value.
	#  2. It is truncated at 100 miles, so any pair farther apart than that is
	#     absent and stays NA. NA therefore means "either farther than 100 miles or
	#     not a valid ZCTA" -- it is not an exact distance the way zipcodeR's was.
	#     grf handles the missingness natively.
	#  3. It is fully symmetric and (zip1, zip2) is unique, so one join direction
	#     suffices and the join cannot duplicate or reorder rows.
	zip_pairs <- tibble(
		zip1 = substr(processed$zip, 1, 5),
		zip2 = substr(processed$Residence_Addresses_Zip, 1, 5)
	)

	nber_distances <- arrow::open_dataset(
			zip_distance_file,
			format = "csv",
			# read the ZIPs as strings; inferred types would drop leading zeros
			schema = arrow::schema(
				zip1 = arrow::string(),
				zip2 = arrow::string(),
				miles_to_zcta5 = arrow::float64()
			),
			skip = 1
		)

	zip_dist_lookup <- arrow::as_arrow_table(distinct(zip_pairs)) %>%
		left_join(nber_distances, by = c("zip1", "zip2")) %>%
		collect() %>%
		mutate(zip_dist = if_else(zip1 == zip2, 0, miles_to_zcta5)) %>%
		select(zip1, zip2, zip_dist)

	zip_dist_vec <- left_join(zip_pairs, zip_dist_lookup, by = c("zip1", "zip2"))$zip_dist

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

		bind_cols(comparison_dataset, processed)
}

