#' Merge and Clean Physician Data
#'
#' @param cms_file path to CMS csv file which provides year of med school graduation per NPI
#' @param nppes_file contains physician data including first name, last name, zip code
#' @param nucc_file path to NUCC crosswalk file which provides a crosswalk between taxonomy codes and human-readable descriptions
#'
#' @return a consolidated dataframe which has the information from all three sources by NPI
#'
clean_physician_data <- function(cms_file, nppes_file, nucc_file) {
	cms_data <- read_csv(cms_file) %>%
	  rename_with(tolower) %>%
		select(npi, grd_yr, med_sch) %>%
		distinct()

	nppes_data <- read_csv(nppes_file) %>%
		rename_with(~tolower(gsub(" ", "_", .x)))

	table(nppes_data$entity_type_code)

	subset_nppes_data <- nppes_data %>%
		select(npi, provider_first_name, provider_middle_name, `provider_last_name_(legal_name)`,
					 provider_business_mailing_address_state_name, provider_business_mailing_address_postal_code,
					 provider_business_mailing_address_state_name, healthcare_provider_taxonomy_code_1,
					 entity_type_code
					 ) %>%
		drop_na(npi) %>%
		filter(entity_type_code == 1)

	nucc_data <- read_csv(nucc_file) %>%
		rename_with(~tolower(gsub(" ", "_", .x)))

	full_data <- left_join(subset_nppes_data, nucc_data, by = c("healthcare_provider_taxonomy_code_1" = "code"))  %>%
		left_join(cms_data, by = "npi")

	full_data <- full_data %>%
		mutate(
			physician = grouping == "Allopathic & Osteopathic Physicians"
		) %>%
		filter(physician)

	full_data
}
