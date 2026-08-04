#!/usr/bin/bash
# Pilot run: one year, a handful of states. The point is to produce the numbers that size
# submit.sh -- per-branch wall time and peak memory -- not to produce output anyone uses.
#
# Scoped by the two environment variables below, so _targets.R is never edited and cannot be
# left scoped by accident. Unset them and the pipeline is back to the full 2018-2025 grid.
#
#SBATCH --job-name=physician-to-voter-pilot
#SBATCH --time=2:00:00
#SBATCH --mail-type=all
#SBATCH --partition=day
#SBATCH --nodes=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=100GB
#SBATCH --output=job_outputs/pilot_out.txt
#SBATCH -e job_outputs/pilot_err.txt

module add R/4.4.1-foss-2022b

# CT and NY are adjacent, so this exercises the cross-border pass rather than only Stage A.
export P2V_YEARS=2018
export P2V_STATES=CT,NY,MA,RI

# crew_controller_local workers are processes on ONE node, and availableCores() reads
# SLURM_CPUS_PER_TASK -- so --cpus-per-task above is what sets the worker count.
R -e "targets::tar_make()"

# Afterwards, read the numbers that size the full run:
#   targets::tar_read(cms_npi_conflicts)
#   targets::tar_read(panel_gap_summary)
#   targets::tar_meta(fields = c("name", "seconds", "bytes")) |>
#     dplyr::arrange(dplyr::desc(seconds))
