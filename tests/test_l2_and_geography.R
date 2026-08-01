## Self-contained checks for the L2 partition helpers and the state adjacency table.
##
## Run from the repo root:   Rscript tests/test_l2_and_geography.R
##
## Builds its own SYNTHETIC L2 hive tree in a temp directory -- no real data, and nothing
## is written inside the repo. Names are deliberately absurd so fixture output can never
## be mistaken for real voter records.

suppressPackageStartupMessages({
  library(arrow); library(tidyverse)
})
source("R/helpers.R"); source("R/l2.R"); source("R/geographic.R")
source("R/clean_physician_data.R")

FAIL <- 0L
ok <- function(label, cond) {
  cond <- isTRUE(cond)
  if (!cond) FAIL <<- FAIL + 1L
  cat(sprintf("  [%s] %s\n", if (cond) "ok" else "FAIL", label))
}

root <- file.path(tempdir(), "p2v_test")
unlink(root, recursive = TRUE)
dir.create(root, recursive = TRUE)
old <- setwd(root)
on.exit(setwd(old), add = TRUE)

## ---------------------------------------------------------------- fixture
## CT/2018 has TWO extracts (the later must win). NY/2019 is absent, standing in for the
## real 2024 MD/MS/NV gap. CT/2025 exercises the occupation column rename.
leaves <- tribble(
  ~state, ~year, ~month, ~day,  ~tag,
  "CT",   2018,  "06",   "01",  "stale",
  "CT",   2018,  "11",   "15",  "current",
  "NY",   2018,  "07",   "04",  "current",
  "CT",   2019,  "6",    "9",   "current",   # unpadded on purpose
  "CT",   2025,  "05",   "20",  "current"
)
for (i in seq_len(nrow(leaves))) {
  L <- leaves[i, ]
  d <- file.path("l2root", paste0("state=", L$state), paste0("year=", L$year),
                 paste0("month=", L$month), paste0("day=", L$day))
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  occ_col <- if (L$year <= 2024) "CommercialData_Occupation" else "ConsumerData_Occupation_of_Person"
  v <- tibble(LALVOTERID = paste0("LAL", L$state, 1:4),
              Voters_FirstName = c("Aaardvarkina","Bloopberta","Squibbly","Fakeworth"),
              Voters_MiddleName = c("Q", NA, "Zebulon", "X"),
              Voters_LastName = if (L$tag == "stale") rep("Staleextract", 4) else
                c("Zzyzxton","Quibblesnort","Fakenheimer","Notarealname"),
              Residence_Addresses_State = L$state)
  v[[occ_col]] <- c("Medical-Physician", "Unknown", NA, "Educator")
  write_parquet(v, file.path(d, "part-0.parquet"))
}
l2_path <- "l2root/state={state}/year={year}"

## -------------------------------------------------- L2 partition resolution
cat("\n== resolve_l2_extract ==\n")
ct18 <- resolve_l2_extract("CT", 2018, l2_path)
ok("resolves a state-year that exists", !is.null(ct18))
ok("picks the LATER of two extracts (11/15, not 06/01)", grepl("month=11/day=15", ct18))
ok("absent state-year returns NULL", is.null(resolve_l2_extract("NY", 2019, l2_path)))
ok("state-year outside the tree returns NULL", is.null(resolve_l2_extract("ZZ", 2018, l2_path)))
ok("unpadded month=6/day=9 resolves", !is.null(resolve_l2_extract("CT", 2019, l2_path)))
ok("the stale extract's rows are not reachable via the resolved leaf",
   !any(open_dataset(ct18) |> collect() |> pull(Voters_LastName) == "Staleextract"))

cat("\n== parse_l2_extract_date ==\n")
ok("padded and unpadded parse to the same date",
   parse_l2_extract_date("x/year=2019/month=6/day=9") ==
     parse_l2_extract_date("x/year=2019/month=06/day=09"))
ok("later extract sorts later",
   parse_l2_extract_date("x/year=2018/month=11/day=15") >
     parse_l2_extract_date("x/year=2018/month=06/day=01"))

cat("\n== path key parsing (L2 nests state OUTSIDE year) ==\n")
ok("get_l2_state reads by key, not position", get_l2_state(ct18) == "CT")
ok("get_l2_year reads by key, not position", get_l2_year(ct18) == 2018)
ok("output subdir FLIPS to year=/state=",
   as.character(build_l2_out_subdir(ct18)) == "year=2018/state=CT")

cat("\n== occupation column by year ==\n")
ok("<=2024 uses CommercialData_Occupation",
   l2_occupation_col(2024) == "CommercialData_Occupation")
ok(">=2025 uses ConsumerData_Occupation_of_Person",
   l2_occupation_col(2025) == "ConsumerData_Occupation_of_Person")
ok("the 2025 fixture really does store the consumer name",
   "ConsumerData_Occupation_of_Person" %in%
     names(open_dataset(resolve_l2_extract("CT", 2025, l2_path)) |> collect()))

## ------------------------------------------------------- state adjacency
cat("\n== state_adjacency ==\n")
adj <- state_adjacency()
all_states <- sort(unique(c(adj$state_a, adj$state_b)))
ok("109 undirected pairs", nrow(adj) == 109)
ok("each pair listed once (no duplicates, no reversed duplicates)",
   nrow(adj) == nrow(distinct(mutate(adj,
     lo = pmin(state_a, state_b), hi = pmax(state_a, state_b)) |> select(lo, hi))))
ok("no state borders itself", !any(adj$state_a == adj$state_b))
ok("49 states have land neighbours (AK and HI have none)", length(all_states) == 49)
ok("AK has no neighbours", length(adjacent_states("AK")) == 0)
ok("HI has no neighbours", length(adjacent_states("HI")) == 0)
ok("adjacency is symmetric under adjacent_states()",
   all(vapply(all_states,
              function(s) all(vapply(adjacent_states(s),
                                     function(t) s %in% adjacent_states(t), logical(1))),
              logical(1))))
ok("DC borders exactly MD and VA", identical(adjacent_states("DC"), c("MD","VA")))
ok("Four Corners point contacts included (AZ-CO)", "CO" %in% adjacent_states("AZ"))
ok("Four Corners point contacts included (NM-UT)", "UT" %in% adjacent_states("NM"))
ok("MI-WI included (real land border via the Upper Peninsula)",
   "WI" %in% adjacent_states("MI"))
ok("RI-NY excluded (water only)", !("NY" %in% adjacent_states("RI")))
ok("MI-IL excluded (water only)", !("IL" %in% adjacent_states("MI")))
ok("MI-NY excluded (water only)", !("NY" %in% adjacent_states("MI")))
ok("MI-PA excluded (water only)", !("PA" %in% adjacent_states("MI")))
ok("MI-MN excluded (water only)", !("MN" %in% adjacent_states("MI")))
# guard against the easy misreading of the rule above: these are MICHIGAN pairs.
# NY-PA is a long land border and must stay in.
ok("NY-PA included (long land border, not a Michigan lake pair)",
   "PA" %in% adjacent_states("NY"))
ok("every abbreviation is a real state or DC",
   all(all_states %in% c(state.abb, "DC")))

## ------------------------------------------------ unmatched_physicians
cat("\n== unmatched_physicians ==\n")
write_csv(tibble(NPI = 1:4,
                 `Provider First Name` = c("Aaardvarkina","Bloopberta","Squibbly","Fakeworth"),
                 `Provider Middle Name` = c("Q", NA, "Zebulon", "X"),
                 `Provider Last Name (Legal Name)` = c("Zzyzxton","Quibblesnort","Fakenheimer","Notarealname"),
                 `Provider Business Mailing Address State Name` = "CT",
                 `Provider Business Mailing Address Postal Code` = "06510",
                 `Healthcare Provider Taxonomy Code_1` = "207R00000X",
                 `Entity Type Code` = 1L), "nppes.csv")
write_csv(tibble(Code = "207R00000X", Grouping = "Allopathic & Osteopathic Physicians"), "nucc.csv")
write_csv(tibble(NPI = 1:4, grd_yr = 1990L, med_sch = "FAKE SCHOOL"), "cms.csv")
phys <- clean_physician_data("cms.csv", "nppes.csv", "nucc.csv", out_pth = "phys")

# Stage A found a strong match for npi 1, a weak one for npi 2, nothing for npi 3.
# npi 4's 0.80 straddles the old 0.85 default and the current 0.75 one, so it pins
# which default is actually in force.
dir.create("lsh/year=2018/state=CT", recursive = TRUE, showWarnings = FALSE)
write_parquet(tibble(npi = c(1, 2, 4), full_name_sim = c(0.99, 0.40, 0.80)),
              "lsh/year=2018/state=CT/part-0.parquet")

u <- unmatched_physicians(phys, "lsh/year=2018/state=CT", "CT", 2018)
ok("strong in-state match is NOT sent cross-border", !(1 %in% u$npi))
ok("weak in-state match IS sent cross-border", 2 %in% u$npi)
ok("physician with no candidate at all IS sent cross-border", 3 %in% u$npi)
ok("returns 3 of 4 physicians", nrow(u) == 3)
ok("default min_name_sim is 0.85, so a 0.80 in-state hit is still retried",
   4 %in% u$npi)
ok("lowering the cutoff to 0.75 exempts the 0.80 case",
   !(4 %in% unmatched_physicians(phys, "lsh/year=2018/state=CT", "CT", 2018,
                                 min_name_sim = 0.75)$npi))
ok("a 0.99 in-state hit is exempt even at the higher default", !(1 %in% u$npi))
# 2019 has no Stage A data, so nobody has an in-state match and all 4 go cross-border.
# If the filter read the hive `year` column instead of the argument it would match 2018
# and return 2, so this pins the {{ }} disambiguation.
ok("the state/year filter uses the arguments, not the hive columns of the same name",
   nrow(unmatched_physicians(phys, "lsh/year=2018/state=CT", "CT", 2019)) == 4)
ok("NULL lsh_pairs sends everyone cross-border",
   nrow(unmatched_physicians(phys, NULL, "CT", 2018)) == 4)
ok("a state with no physicians returns NULL",
   is.null(unmatched_physicians(phys, "lsh/year=2018/state=CT", "NY", 2018)))

cat(sprintf("\n%s  (%d failure%s)\n",
            if (FAIL == 0) "ALL CHECKS PASSED" else "FAILURES PRESENT",
            FAIL, if (FAIL == 1) "" else "s"))
if (FAIL > 0) quit(status = 1)
