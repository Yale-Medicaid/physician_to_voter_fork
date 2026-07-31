dollar_to_float <- function(x){
	as.numeric(gsub("\\$", "", x))
}

#' Save voter data as parquet files
#'
#' TODO: list is to have these saved in a hive format - we are almost there, so it
#' makes sense to tweak when I have the time to rerun the codebase
#' makes sense to tweak when I have the time to rerun the codebase
#'
#' @param raw_l2_files a character vector with the locations of all the raw l2 files
#'
#' @return a list of cleaned, standardized parquet files
#'
process_voter_data <- function(raw_l2_files) {
	output_folder_names <- gsub(".*Uniform--(.*).tab","trunk/derived/processed_voter_data/\\1",raw_l2_files)
	walk(output_folder_names, dir.create, showWarnings=F, recursive=T)

	plan(multisession, workers=30)

	yale_schema <- c(
		CommercialData_Education = "c",
		CommercialData_Education = "c",
		DateConfidence_Description = "c",
		CommercialData_EstHomeValue = "c",
		CommercialData_HomePurchasePrice = "c",
		CommercialData_EstimatedHHIncome = "c",
		CommercialData_EstimatedHHIncomeAmount = "c",
		CommercialData_EstimatedHHIncomeAmount = "c",
		CommercialData_HHComposition = "c",
		CommercialData_HomePurchaseDate = "c",
		CommercialData_HomePurchasePrice = "c",
		CommercialData_LikelyUnion = "c",
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
		Residence_Families_HHCount = "c",
		Residence_HHGender_Description = "c",
		Residence_HHParties_Description = "c",
		Residence_HHParties_Description = "c",
		Voters_Age = "n",
		Voters_BirthDate = "c",
		Voters_Gender = "c",
		Voters_CalculatedRegDate = "c",
		Voters_OfficialRegDate = "c"
	)

	datavant_schema <- c(
		Residence_Addresses_AddressLine = "c",
		Residence_Addresses_ApartmentNum = "c",
		Residence_Addresses_ApartmentType = "c",
		Residence_Addresses_CensusBlock = "c",
		Residence_Addresses_CensusBlockGroup = "c",
		Residence_Addresses_CensusTract = "c",
		Residence_Addresses_City = "c",
		Residence_Addresses_ExtraAddressLine = "c",
		Residence_Addresses_HouseNumber = "c",
		Residence_Addresses_Latitude = "n",
		Residence_Addresses_Longitude = "n",
		Residence_Addresses_PrefixDirection = "c",
		Residence_Addresses_State = "c",
		Residence_Addresses_StreetName = "c",
		Residence_Addresses_SuffixDirection = "c",
		Residence_Addresses_Zip = "c",
		Residence_Addresses_ZipPlus4 = "c",
		Voters_Age = "n",
		Voters_BirthDate = "c",
		Voters_FIPS = "c",
		Voters_FirstName = "c",
		Voters_Gender = "c",
		Voters_LastName = "c",
		Voters_MiddleName = "c",
		Voters_NameSuffix = "c",
		VoterTelephones_CellPhoneFormatted = "c"
	)

	combined_schema <- c(LALVOTERID  = "c", yale_schema, datavant_schema)

	transfer_to_parquets <- function(file_name, out_folder_name){
		print(paste(Sys.time(), "Starting to write file", file_name))
		save_callback <- function(x,pos) {

			x <- x %>%
				mutate(
					Voters_BirthDate = as.Date(Voters_BirthDate, format = "%m/%d/%Y"),
					Voters_OfficialRegDate = as.Date(Voters_BirthDate, format = "%m/%d/%Y"),
					Voters_CalculatedRegDate = as.Date(Voters_BirthDate, format = "%m/%d/%Y")
				) %>%
				mutate(across(where(is.character), ~iconv(.x, "UTF-8", "UTF-8", sub = "")))

			x %>%
				select(any_of(names(combined_schema))) %>%
				write_parquet(paste0(out_folder_name,"/chunk_", pos,".parquet"))
		}

		read_tsv_chunked(file_name,
										 SideEffectChunkCallback$new(save_callback),
										 col_types = combined_schema,
										 chunk_size = 10^5
		)

		print(paste(Sys.time(), "Done to writing file", file_name))
	}

	future_map2(raw_l2_files, output_folder_names, transfer_to_parquets)

	return(list.files("trunk/derived/processed_voter_data/", recursive = T, full.names=T))
}


