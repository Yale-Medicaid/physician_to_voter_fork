#' Physician-side inputs for one year
#'
#' @description Combines three sources into one row per NPI for a single year:
#'
#' - **NBER `core`** (per year) -- names and addresses. This is the only per-year source;
#'   it is what makes the physician side vary across the panel.
#' - **NBER `ptaxcode`**, two extracts only -- taxonomy code. NBER's `core` has no taxonomy
#'   field. Their per-year `ptaxcode` coverage is too irregular to build a panel from, so
#'   the latest extract is used for everyone currently enumerated, with the earliest
#'   unioned in to recover NPIs deactivated since. See `nppes_taxonomy_url()`.
#' - **NUCC crosswalk** and **CMS Physician Compare** -- taxonomy descriptions, and
#'   graduation year / medical school.
#'
#' **Address.** State and ZIP come from the *practice location* (`plocstatename`,
#' `ploczip`), falling back to the mailing address where practice is missing. Practice
#' location is what `zip_dist` is meant to measure distance from -- a mailing address can be
#' a billing office or a PO box. `addr_source` records which was used, since a column whose
#' meaning varies by row should say so.
#'
#' Note the pipeline previously used the mailing address throughout, which never matched
#' what `figures/processing.png` described.
#'
#' @param nppes_core_file per-year NBER core file from `download_nppes_core()`
#' @param taxonomy_latest,taxonomy_earliest NBER ptaxcode files from
#'   `download_nppes_taxonomy()`
#' @param cms_file CMS Physician Compare csv (grd_yr, med_sch)
#' @param nucc_file NUCC taxonomy crosswalk
#' @param year the year being built
#' @param out_pth glue template; output is partitioned `year=/state=`
#'
#' @return `out_pth` -- one row per NPI, asserted distinct
clean_physician_data <- function(nppes_core_file, taxonomy_latest, taxonomy_earliest,
														 cms_file, nucc_file, year,
																 out_pth = "trunk/derived/physician_data/year={year}") {
	out_pth <- glue::glue(out_pth)
	unlink(out_pth, recursive = TRUE)

	# An NPI carrying more than one (grd_yr, med_sch) combination is dropped entirely --
	# there is no principled way to choose, and keeping one would fan that physician out
	# through every downstream join. count_cms_npi_conflicts() reports the cost.
	cms_raw <- read_csv(cms_file, show_col_types = FALSE) %>%
		rename_with(tolower) %>%
		select(npi, grd_yr, med_sch) %>%
		distinct()

	conflicted_npi <- cms_raw %>%
		count(npi) %>%
		filter(n > 1) %>%
		select(npi)

	cms_data <- anti_join(cms_raw, conflicted_npi, by = "npi")

	# taxonomy: npi -> primary code. seq == 1 is the first listed taxonomy, matching the
	# `_1` suffix the dissemination file used, so the filter is unchanged in meaning.
	#
	# Latest first, then any NPI seen only in the earliest extract -- those are providers
	# deactivated at some point in the panel, who would otherwise drop out of the early
	# years entirely.
	read_taxonomy <- function(pth) {
		arrow::open_dataset(pth) %>%
			filter(seq == 1) %>%
			select(npi, taxonomy_code = ptaxcode) %>%
			collect()
	}

	tax_latest <- read_taxonomy(taxonomy_latest)

	taxonomy <- bind_rows(
		tax_latest,
		anti_join(read_taxonomy(taxonomy_earliest), tax_latest, by = "npi")
	)

	nucc_data <- read_csv(nucc_file, show_col_types = FALSE) %>%
		rename_with(~tolower(gsub(" ", "_", .x)))

	providers <- read_nppes_core(nppes_core_file) %>%
		select(npi, entity, pfname, pmname, plname,
					 plocstatename, ploczip, pmailstatename, pmailzip) %>%
		# entity 1 is an individual; 2 is an organisation
		filter(entity == 1) %>%
		collect() %>%
		mutate(
			# practice location, falling back to mailing where practice is absent
			addr_source = if_else(!is.na(plocstatename) & plocstatename != "",
														"practice", "mailing"),
			state = if_else(addr_source == "practice", plocstatename, pmailstatename),
			zip   = if_else(addr_source == "practice", ploczip, pmailzip)
		) %>%
		select(npi, provider_first_name = pfname, provider_middle_name = pmname,
					 provider_last_name = plname, state, zip, addr_source)

	full_data <- providers %>%
		anti_join(conflicted_npi, by = "npi") %>%
		left_join(taxonomy, by = "npi") %>%
		left_join(nucc_data, by = c("taxonomy_code" = "code")) %>%
		left_join(cms_data, by = "npi") %>%
		filter(grouping == "Allopathic & Osteopathic Physicians") %>%
		mutate(year = as.integer(year))

	write_dataset(full_data, out_pth, partitioning = "state")

	return_out_pth_check_distinct(out_pth, distinct_col = "npi")
}


#' Count NPIs carrying conflicting CMS records
#'
#' @description `clean_physician_data()` drops any NPI with more than one
#' (grd_yr, med_sch) combination. This measures how much that costs, and which field is
#' responsible -- two graduation years is a different data-quality story from two medical
#' schools. Small, so it stays an in-memory target: `targets::tar_read(cms_npi_conflicts)`.
#'
#' @param cms_file path to the CMS Physician Compare csv
#'
#' @return a one-row tibble of counts and shares
count_cms_npi_conflicts <- function(cms_file) {
	read_csv(cms_file, show_col_types = FALSE) %>%
		rename_with(tolower) %>%
		select(npi, grd_yr, med_sch) %>%
		distinct() %>%
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
			n_grd_yr_only = sum(n_rows > 1 & n_grd_yr > 1 & n_med_sch == 1),
			n_med_sch_only = sum(n_rows > 1 & n_grd_yr == 1 & n_med_sch > 1),
			n_both = sum(n_rows > 1 & n_grd_yr > 1 & n_med_sch > 1)
		)
}
