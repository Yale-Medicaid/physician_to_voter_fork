#!/usr/bin/bash
# Full run: 2018-2025, all states. 408 state-year branches through Stages A-D.
#
# The resource requests below are STARTING POINTS, not measured values -- nothing has run
# against real L2 yet. Size them from small_submit.sh before trusting a long job to them.
#
#SBATCH --job-name=physician-to-voter
#SBATCH --time=24:00:00
#SBATCH --mail-type=all
#SBATCH --partition=week
#SBATCH --nodes=1
#SBATCH --cpus-per-task=32
#SBATCH --mem=478GB
#SBATCH --output=job_outputs/out.txt
#SBATCH -e job_outputs/err.txt

module add R/4.4.1-foss-2022b

# Memory is the binding constraint, not CPU. read_l2_partition() collect()s a whole
# state-year voter file into R, and crew runs one worker per core on this single node -- so
# peak memory is roughly --cpus-per-task * (largest state-year partition). Raising
# --cpus-per-task without raising --mem is how this job gets OOM-killed on California.
R -e "targets::tar_make()"
