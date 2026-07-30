library(tidyverse)

## Requires access to the mounted Yale network drive; there is no cached
## alternative, as the voter file is licensed and cannot be redistributed.

# Take zip files from B drive. This won't work if you haven't been given access
# by Yale, and you must mount the drive in the right place
zip_files <- list.files("B:/ARCHIVE--SFTP--OLD VM2Uniform Format Files", pattern="*.zip", full.names = T)
# Subset to include only 2018 files
zip_files <- keep(zip_files, ~ grepl("2018",.x))

# Take first (earliest) record from each state
zip_files <- tibble(file_names = zip_files)  %>%
	mutate(state = sub(".*--([A-Z]{2})--.*", "\\1", file_names)) %>%
	group_by(state) %>%
	filter(row_number() == 1 ) %>%
	ungroup() %>%
	pull(file_names)

# Check that we have 51 files corresponding to all states + DC
stopifnot(length(zip_files) == 51)

# Create output folders
folder_names <- gsub(".*Uniform--(.*).zip", "data/rawl2/\\1",zip_files)
walk(folder_names, dir.create, showWarnings=T)

# Unzip Files
walk2(zip_files, folder_names, ~unzip(.x, exdir=.y))
