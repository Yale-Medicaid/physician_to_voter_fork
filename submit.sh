#!/usr/bin/bash
#SBATCH --job-name=physician-to-voter
#SBATCH --time=2:00:00
#SBATCH --mail-type=all
#SBATCH --partition=scavenge
#SBATCH --nodes=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=47GB
#SBATCH --output=job_outputs/out.txt
#SBATCH -e job_outputs/err.txt

module add R/4.4.1-foss-2022b

R -e "targets::tar_make(nppes_taxonomy_files)"
