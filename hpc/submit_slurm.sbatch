#!/bin/bash
#SBATCH --job-name=nf-variant-pipeline
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=12:00:00
#SBATCH --output=logs/%x_%j.out
# Edit for your site: partition/account, and `module load` names.
##SBATCH --partition=compute
##SBATCH --account=YOUR_ACCOUNT
#
# Submit from the repository root:  mkdir -p logs && sbatch hpc/submit_slurm.sbatch
set -euo pipefail
cd "${SLURM_SUBMIT_DIR:-$PWD}"

# Site modules (names vary; failures are ignored if the tool is already on PATH).
module load apptainer 2>/dev/null || module load singularity 2>/dev/null || true

# Nextflow head job; Nextflow submits each process to SLURM using the `slurm`
# profile in nextflow.config (Singularity/Apptainer containers). Edit
# `process.queue` there for your cluster.
module load nextflow 2>/dev/null || true
export NXF_SINGULARITY_CACHEDIR="${NXF_SINGULARITY_CACHEDIR:-${SCRATCH:-$HOME}/.nxf-sif}"

nextflow run main.nf -profile slurm
