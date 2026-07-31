#' Merge and Clean Physician Data
#'
#' @param cms_file path to CMS csv file which provides year of med school graduation per NPI
#' @param nppes_file contains physician data including first name, last name, zip code
#' @param nucc_file path to NUCC crosswalk file which provides a crosswalk between taxonomy codes and human-readable descriptions
#' @param out_pth directory to write the consolidated dataset to
#'
#' @return `out_pth` -- a parquet dataset with the information from all three sources,
#'   one row per NPI. Distinctness in `npi` is asserted before the path is returned.
#'
clean_physician_data <- function(cms_file, nppes_file, nucc_file,
																 out_pth = "trunk/derived/physician_data") {
	unlink(out_pth, recursive = TRUE)

	# One row per NPI. An NPI carrying more than one (grd_yr, med_sch) combination is
	# dropped rather than arbitrarily resolved: there is no principled way to pick, and
	# silently keeping one would fan the row out through every downstream join and
	# duplicate that physician's candidate pairs. See count_cms_npi_conflicts() for how
	# often this bites.
	cms_raw <- read_csv(cms_file) %>%
	  rename_with(tolower) %>%
		select(npi, grd_yr, med_sch) %>%
		distinct()

	conflicted_npi <- cms_raw %>%
		count(npi) %>%
		filter(n > 1) %>%
		select(npi)

	cms_data <- cms_raw %>%
		anti_join(conflicted_npi, by = "npi")

	nppes_data <- read_csv(nppes_file) %>%
		rename_with(~tolower(gsub(" ", "_", .x)))

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

	# anti_join before the CMS join, not after: dropping the conflicted rows from cms_data
	# alone is not enough, because a left join keeps the NPPES row with grd_yr/med_sch as
	# NA -- the physician would survive without CMS data rather than being dropped.
	# NPIs simply *absent* from CMS are still kept, with NA grd_yr, as before.
	full_data <- left_join(subset_nppes_data, nucc_data, by = c("healthcare_provider_taxonomy_code_1" = "code"))  %>%
		anti_join(conflicted_npi, by = "npi") %>%
		left_join(cms_data, by = "npi")

	full_data <- full_data %>%
		mutate(
			physician = grouping == "Allopathic & Osteopathic Physicians"
		) %>%
		filter(physician)

	write_dataset(full_data, out_pth)

	return_out_pth_check_distinct(out_pth, distinct_col = "npi")
}


#' Count NPIs carrying conflicting CMS records
#'
#' @description `clean_physician_data()` drops any NPI with more than one
#' (grd_yr, med_sch) combination. This measures how much that costs, and which field is
#' responsible -- a provider listed with two graduation years is a different data-quality
#' story from one listed with two medical schools.
#'
#' Kept separate from `clean_physician_data()` so the number is inspectable on its own
#' (`targets::tar_read(cms_npi_conflicts)`) rather than buried in a log line.
#'
#' @param cms_file path to the CMS csv
#'
#' @return a one-row tibble of counts and shares
count_cms_npi_conflicts <- function(cms_file) {
	cms_data <- read_csv(cms_file) %>%
		rename_with(tolower) %>%
		select(npi, grd_yr, med_sch) %>%
		distinct()

	cms_data %>%
		group_by(npi) %>%
		summarize(
			n_rows = n(),
			n_grd_yr = n_distinct(grd_yr),
			n_med_sch = n_distinct(med_sch),
			.groups = "drop"
		) %>%
		summarize(
			n_npi = n(),
			n_conflicting = sum(n_rows > 1),
			pct_conflicting = n_conflicting / n_npi,
			max_rows_per_npi = max(n_rows),
			# which field disagrees, among the conflicting NPIs
			n_grd_yr_only = sum(n_rows > 1 & n_grd_yr > 1 & n_med_sch == 1),
			n_med_sch_only = sum(n_rows > 1 & n_grd_yr == 1 & n_med_sch > 1),
			n_both = sum(n_rows > 1 & n_grd_yr > 1 & n_med_sch > 1)
		)
}
