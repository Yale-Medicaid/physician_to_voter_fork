# Dependency Graph

Generated from `_targets.R`, so it is accurate as of the commit you are reading. Regenerate it
after changing the graph:

```r
m <- targets::tar_mermaid(targets_only = TRUE, legend = FALSE)
m <- gsub(":::[a-zA-Z]+", "", m)
writeLines(m[!grepl("classDef|linkStyle", m)], "docs/_graph.mmd")
```

Then paste the contents into the fence below. Build status is deliberately stripped — the
diagram describes structure, not whether one machine happens to be up to date.

Rounded nodes are single targets; square nodes are dynamically branched, one instance per
state-year or per year.

```mermaid
graph LR
  style Graph fill:#FFFFFF00,stroke:#000000;
  subgraph Graph
    direction LR
    xbe51850f2c99ad90(["cms_file"]) --> x769ee1ef9a310e3a(["cms_npi_conflicts"])
    x51282908e97f9775["physician_data"] --> xdfd789e4547a5021["cross_border_pairs"]
    xfd6051b0357f0a47["lsh_pairs"] --> xdfd789e4547a5021["cross_border_pairs"]
    x3f05129654f499a8["l2_extracts"] --> xdfd789e4547a5021["cross_border_pairs"]
    xc592eafe0b371ce9(["zip_centroid_file"]) --> xdfd789e4547a5021["cross_border_pairs"]
    x26cf19d2d1da82b7(["states"]) --> x3f05129654f499a8["l2_extracts"]
    xf9ac23fbc741da6f(["years"]) --> x3f05129654f499a8["l2_extracts"]
    x51282908e97f9775["physician_data"] --> xfd6051b0357f0a47["lsh_pairs"]
    x3f05129654f499a8["l2_extracts"] --> xfd6051b0357f0a47["lsh_pairs"]
    xc592eafe0b371ce9(["zip_centroid_file"]) --> xfd6051b0357f0a47["lsh_pairs"]
    xf9ac23fbc741da6f(["years"]) --> x3fcd6131cf856810["nppes_core_files"]
    x51282908e97f9775["physician_data"] --> xf8f655140828d992(["panel_gap_summary"])
    x3f05129654f499a8["l2_extracts"] --> xf8f655140828d992(["panel_gap_summary"])
    x9c710fd6648f09c9(["physician_year_panel_data"]) --> xf8f655140828d992(["panel_gap_summary"])
    xbe51850f2c99ad90(["cms_file"]) --> x51282908e97f9775["physician_data"]
    x3fcd6131cf856810["nppes_core_files"] --> x51282908e97f9775["physician_data"]
    xf0384b42c38f077b(["nppes_taxonomy_files"]) --> x51282908e97f9775["physician_data"]
    x2562a43e639e1b04(["nucc_taxonomy_file"]) --> x51282908e97f9775["physician_data"]
    xf9ac23fbc741da6f(["years"]) --> x51282908e97f9775["physician_data"]
    x9c710fd6648f09c9(["physician_year_panel_data"]) --> x1bcf29a695bc877a(["physician_matches"])
    x4425070ee2859224["scored_pairs"] --> x9c710fd6648f09c9(["physician_year_panel_data"])
    x3f05129654f499a8["l2_extracts"] --> x735888b6bc47aa94(["physician_year_panel_filled"])
    x51282908e97f9775["physician_data"] --> x735888b6bc47aa94(["physician_year_panel_filled"])
    x9c710fd6648f09c9(["physician_year_panel_data"]) --> x735888b6bc47aa94(["physician_year_panel_filled"])
    x3bd924c9708d8819(["labelled_training_files"]) --> x92f861f9e8d56419(["rf_model"])
    xfd6051b0357f0a47["lsh_pairs"] --> x4425070ee2859224["scored_pairs"]
    xdfd789e4547a5021["cross_border_pairs"] --> x4425070ee2859224["scored_pairs"]
    x92f861f9e8d56419(["rf_model"]) --> x4425070ee2859224["scored_pairs"]
    xf9ac23fbc741da6f(["years"]) --> x4425070ee2859224["scored_pairs"]
    
  end
```

For an interactive version, with build status, run `targets::tar_visnetwork()` locally.
