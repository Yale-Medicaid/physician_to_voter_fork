library(targets)
library(tarchetypes)

# L2 lives on the HPC, partitioned state=XX/year=YYYY/month=MM/day=DD. The template
# deliberately stops at year= : a single state-year can hold several month=/day=
# extracts, and resolve_l2_extract() picks the latest at run time.
l2_path <- "/home/pg589/project_pi_cdn7/pg589/l2/transformed/vm2/uniform.parquet/state={state}/year={year}"

source("R/clean_physician_data.R")
source("R/locality_sensitive_hash.R")
source("R/random_forest.R")
source("R/l2.R")
source("R/helpers.R")
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
	# The state-year grid. Crossed rather than mapped over a discovered manifest, so the
	# graph stays static and readable; state-years with no data resolve to NULL inside
	# resolve_l2_extract() and drop out of downstream aggregation on their own.
	targets::tar_target(years,
											2018:2025,
											iteration = "vector"),
	targets::tar_target(states,
											sort(c(state.abb, "DC")),
											iteration = "vector"),

	# Latest L2 extract per state-year. NULL for absent state-years (2024 MD, MS, NV).
	targets::tar_target(l2_extracts,
											resolve_l2_extract(states, years, l2_path),
											pattern = cross(years, states),
											format = "file"),

	# clean physician data
	tar_target(cms_file, "trunk/raw/DAC_NationalDownloadableFile.csv", format = "file"),
	tar_target(nppes_file, "trunk/raw/NPPES_Data_Dissemination_February_2023/npidata_pfile_20050523-20230212.csv", format = "file"),
	tar_target(nucc_taxonomy_file, "trunk/raw/nucc_taxonomy_230.csv", format = "file"),
	# NBER ZCTA centroid file (Census internal points), 890 KB.
	# https://data.nber.org/distance/zip/2024/centroid/gaz2024zcta5centroid.csv
	# Columns: zcta5, intptlat, intptlong. locality_sensitive_hash() computes
	# great-circle distances from these directly, which is what NBER's own distance
	# files contain -- see that function for why we compute rather than look up.
	tar_target(zip_centroid_file, "trunk/raw/gaz2024zcta5centroid.csv", format = "file"),

	tar_target(physician_data,clean_physician_data(cms_file, nppes_file, nucc_taxonomy_file), format = "file"),

	# How much the "drop NPIs with conflicting CMS records" rule in
	# clean_physician_data() actually costs, and which field disagrees. Small, so it
	# stays in memory -- read it with targets::tar_read(cms_npi_conflicts).
	targets::tar_target(cms_npi_conflicts,
											count_cms_npi_conflicts(cms_file)),

	# Stage A -- candidate pairs, one branch per state-year. Branches whose l2_extracts
	# entry is NULL return NULL and drop out of aggregation. Note map() still creates a
	# branch for those, so the NULL guard inside the function is doing real work.
	targets::tar_target(lsh_pairs,
											locality_sensitive_hash(physician_data, l2_extracts, zip_centroid_file),
											pattern = map(l2_extracts),
											format = "file"),

	tar_target(labelled_training_files, list.files("trunk/raw/labelled_training_data/", full.names=T), format = "file"),

	# Trained once on the 2018 labels and reused for every year. Small, so in-memory.
	targets::tar_target(rf_model,
											train_rf_model(labelled_training_files)),

	# Stage C -- combine a year's states, compute n, then predict. Per year because grf
	# needs a materialised matrix and eight years of national pairs will not fit.
	targets::tar_target(scored_pairs,
											score_pairs(lsh_pairs, rf_model, years),
											pattern = map(years),
											format = "file")



)

