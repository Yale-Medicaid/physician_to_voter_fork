library(tidyverse)
library(targets)
library(arrow)
library(readxl)

set.seed(0)

rough_data <- tar_read(lshed_data)
rough_data$match<- NA
rough_data <- rough_data %>% 
	dplyr::relocate(
		match, zip_dist, year_dist, full_name.x, full_name.y, 
		CommercialData_Occupation
	)   
training_data <- slice_sample(rough_data, n = 1500) %>% 
	mutate(observation = row_number())

anthony_df <- slice_sample(training_data, n = 350)
ben_df <- slice_sample(training_data, n = 800)
dohyun_df <- slice_sample(training_data, n = 350)

write_parquet(anthony_df, "trunk/raw/unlabelled_training_data/anthony.parquet")
write_parquet(dohyun_df, "trunk/raw/unlabelled_training_data/dohyun.parquet")
write_parquet(ben_df, "trunk/raw/unlabelled_training_data/ben.parquet")

MD_data <- rough_data %>% 
	filter(Voters_NameSuffix == "MD")  %>% 
	mutate(match = T)
write_parquet(MD_data, "trunk/raw/labelled_training_data/MD_data.parquet")

negative_age_data <-  rough_data %>% 
	filter(year_dist < 10) %>% 
	mutate(match = F)  %>% 
	slice_sample(n = 800) 

write_parquet(negative_age_data, "trunk/raw/labelled_training_data/negative_age.parquet")



