library(glue)
library(arrow)
library(yesno)

df <- read_parquet("trunk/raw/labelled_training_data/ben.parquet")
n <- nrow(df)

for (i in 504:n) {
	print(glue("Iteration {i} out of {n}"))
	
	print(glue("
							>     name_1:                       {df$full_name.x[i]} 
							>     name_2:                       {df$full_name.y[i]} 
							>     zip_dist:                     {df$zip_dist[i]} 
							>     year_dist:                    {df$year_dist[i]}
							>     Occupation:                   {df$CommercialData_Occupation[i]}
							>     Number of Candidates for NPI: {df$n[i]}
						 "
						 ))
	
	
	df$match[i] <- yesno2("Do These Records Match?")
}

write_parquet(df, "trunk/raw/labelled_training_data/ben.parquet")

dh_data <- read_parquet("trunk/raw/labelled_training_data/dohyun.parquet")

dh_data$match %>% mean()
df$match %>% mean()



ag_tbl <- inner_join(
	select(dh_data, observation, match),
	select(df, observation, match), 
	by = "observation")

(ag_tbl$match.x == ag_tbl$match.y) %>% mean()

vcd::Kappa(table(ag_tbl$match.x, ag_tbl$match.y))

# 
# df %>% 
# 	group_by(EthnicGroups_EthnicGroup1Desc) %>% 
# 	summarize(
# 		p25_n = quantile(n, .25), 
# 		p50_n = quantile(n, .5), 
# 		p75_n = quantile(n, .75), 
# 						)
