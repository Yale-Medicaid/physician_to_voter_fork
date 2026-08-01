make_match_diagnostic_plots <- function(matches, physicians) {
  age_gap_plot_path <- "figures/age_dist_hist.pdf"

  matches |>
    ggplot2::ggplot(ggplot2::aes(x = year_dist)) +
    ggplot2::geom_histogram() +
    ggplot2::xlab("Years Between Birth and Graducation From Med School") +
    ggplot2::ylab("Count") +
    ggplot2::xlim(c(15, 45)) +
    ggplot2::ggtitle("Distribution of Age Gaps In Matched Data") +
    ggplot2::theme(legend.position = "none")
  ggplot2::ggsave(file = age_gap_plot_path, width = 4.5, height = 2.5)


  phys_by_state <- physicians |>
    dplyr::group_by(provider_business_mailing_address_state_name) |>
    dplyr::summarize(n = dplyr::n()) |>
    dplyr::filter(n > 1000,
                  nchar(provider_business_mailing_address_state_name) == 2)

  matches_by_state <- matches |>
    dplyr::group_by(Residence_Addresses_State) |>
    dplyr::summarize(n = dplyr::n())


  num_matched_path <- "figures/matches_by_state.pdf"

  dplyr::inner_join(phys_by_state, matches_by_state,
                    by = dplyr::join_by(provider_business_mailing_address_state_name ==
                                          Residence_Addresses_State)) |>
    tidyr::pivot_longer(cols = c(n.x, n.y)) |>
    dplyr::mutate(
      dataset = ifelse(name == "n.x", "Number of Physicians",
                       "Number of Matched Physicians")
    ) |>
    ggplot2::ggplot(ggplot2::aes(x = reorder(provider_business_mailing_address_state_name,
                                             value),
                                 y = value, fill = dataset)) +
    ggplot2::geom_col(position = "dodge") +
    ggplot2::coord_flip() +
    ggplot2::xlab("State") +
    ggplot2::xlab("N") +
    ggplot2::ggtitle("Number of Matched Physicians by State") +
    ggplot2::theme(legend.position = "none")
  ggplot2::ggsave(num_matched_path, width = 4.5, height = 2.5)

  c(age_gap_plot_path, num_matched_path)
}
