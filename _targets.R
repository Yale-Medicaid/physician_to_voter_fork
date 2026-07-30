library(targets)
library(tarchetypes)

source("R/extract_l2.R")
source("R/clean_physician_data.R")
source("R/locality_sensitive_hash.R")
source("R/random_forest.R")
#source("R/match_diagnostics.R")


tar_option_set(packages = c("arrow",  "zoomerjoin", "lubridate", "tidyverse",
														"furrr", "digest", "lubridate", "grf"
														),
							 garbage_collection = T,
							 # replaces the deprecated format = "file_fast"
							 trust_timestamps = TRUE,
							 )

# This determines how many threads Zoomerjoin will use
Sys.setenv(RAYON_NUM_THREADS=30)

list(
	# clean physician data
	tar_target(cms_file, "trunk/raw/DAC_NationalDownloadableFile.csv", format = "file"),
	tar_target(nppes_file, "trunk/raw/NPPES_Data_Dissemination_February_2023/npidata_pfile_20050523-20230212.csv", format = "file"),
	tar_target(nucc_taxonomy_file, "trunk/raw/nucc_taxonomy_230.csv", format = "file"),
	tar_target(raw_voter_files,list.files("trunk/raw/rawl2/", pattern = "*.tab", full.names=T, recursive = T),format = "file"),

	# NBER ZIP Code Distance Database, 100-mile radius, ZCTA-based.
	# https://data.nber.org/distance/zip/2024/100miles/gaz2024zcta5distance100miles.csv
	# Columns: zip1, zip2, miles_to_zcta5. Pairs beyond 100 miles are absent, and
	# same-ZIP pairs are absent too -- see locality_sensitive_hash() for how both
	# are handled.
	tar_target(zip_distance_file, "trunk/raw/gaz2024zcta5distance100miles.csv", format = "file"),

	tar_target(physician_data,clean_physician_data(cms_file, nppes_file, nucc_taxonomy_file), format = "parquet"),

	tar_target(voter_files,
						 process_voter_data(raw_voter_files),
						 format = "file"
						 ),

	# Run LSH To create 'rough' / blocked dataset
	tar_target(
		lshed_data, locality_sensitive_hash(physician_data, voter_files, zip_distance_file),
		format = "parquet"
	),

	tar_target(labelled_training_files, list.files("trunk/raw/labelled_training_data/", full.names=T), format = "file"),

	tar_target(rf_match_data, add_rf_match_predictions_to_df(labelled_training_files, lshed_data))



)

