library(targets)
library(tarchetypes)

source("code/01_extract_l2.R")
source("code/03_clean_physician_data.R")
source("code/04_locality_sensitive_hash.R")
source("code/05_match_model.R")
source("code/06_random_forest.R")
#source("code/match_diagnostics.R")
#source("code/random_forest_match_model.R")


tar_option_set(packages = c("arrow",  "zoomerjoin", "lubridate", "zipcodeR", "tidyverse",
														"furrr", "digest", "lubridate", "grf"
														),
							 garbage_collection = T,
							 )

# This determines how many threads Zoomerjoin will use
Sys.setenv(RAYON_NUM_THREADS=30)

list(
	# clean physician data
	tar_target(cms_file, "data/DAC_NationalDownloadableFile.csv", format = "file_fast"),
	tar_target(nppes_file, "data/NPPES_Data_Dissemination_February_2023/npidata_pfile_20050523-20230212.csv", format = "file_fast"),
	tar_target(nucc_taxonomy_file, "data/nucc_taxonomy_230.csv", format = "file_fast"),
	tar_target(raw_voter_files,list.files("data/rawl2/", pattern = "*.tab", full.names=T, recursive = T),format = "file_fast"),

	tar_target(physician_data,clean_physician_data(cms_file, nppes_file, nucc_taxonomy_file), format = "parquet"),

	tar_target(voter_files,
						 process_voter_data(raw_voter_files),
						 format = "file_fast"
						 ),

	# Run LSH To create 'rough' / blocked dataset
	tar_target(
		lshed_data, locality_sensitive_hash(physician_data, voter_files),
		format = "parquet"
	),

	tar_target(labelled_training_files, list.files("data/labelled_training_data/", full.names=T), format = "file_fast"),

	tar_target(rf_match_data, add_rf_match_predictions_to_df(labelled_training_files, lshed_data)),

	# This is based on a decision rule that Jacob came up with
	tar_target(dt_match_data,  descision_tree_matcher(lshed_data))



)

