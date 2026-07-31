make_match_diagnostic_plots <- function(matches, physicians) {
	age_gap_plot_path <- "figures/age_dist_hist.pdf"
	
	matches %>% 
		ggplot(aes(x=year_dist)) + 
		geom_histogram() + 
		xlab("Years Between Birth and Graducation From Med School") + 
		ylab("Count") + 
		xlim(c(15,45)) + 
		ggtitle("Distribution of Age Gaps In Matched Data")  + 
		theme(legend.position = "none")
	ggsave(file =age_gap_plot_path, width=4.5, height=2.5)
	
	
	phys_by_state <- physicians %>%
		group_by(provider_business_mailing_address_state_name) %>%
		summarize(n= n()) %>%
		filter(n>1000, nchar(provider_business_mailing_address_state_name)==2)
	
	matches_by_state <- matches %>% 
		group_by(Residence_Addresses_State) %>%
		summarize(n=n())
	
	
	num_matched_path <- "figures/matches_by_state.pdf"
		
	inner_join(phys_by_state, matches_by_state, by=c("provider_business_mailing_address_state_name" = "Residence_Addresses_State")) %>%
		pivot_longer(cols = c(n.x, n.y))  %>%
		mutate(
			dataset = ifelse(name=="n.x", "Number of Physicians", "Number of Matched Physicians") 
		) %>%
		ggplot(aes(x=reorder(provider_business_mailing_address_state_name, value), y = value, fill = dataset)) + 
		geom_col(position = "dodge") + 
		coord_flip() + 
		xlab("State") + 
		xlab("N")  + 
		ggtitle("Number of Matched Physicians by State") + 
		theme(legend.position = "none")
	ggsave(num_matched_path, width=4.5, height=2.5)
	
	c(age_gap_plot_path, num_matched_path)
}