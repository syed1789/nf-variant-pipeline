#!/usr/bin/env bash
# Download a real public SARS-CoV-2 Illumina run (ENA ERR10730304, amplicon
# sequencing of a clinical isolate) plus the Wuhan-Hu-1 reference (NC_045512.2),
# and index the reference. Output layout matches what main.nf expects.
set -euo pipefail
cd "$(dirname "$0")/.."
RUN=ERR10730304
FTP=https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR107/004/$RUN
mkdir -p test_data
curl -fsSL "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=NC_045512.2&rettype=fasta&retmode=text" \
     -o test_data/reference.fasta
curl -fsSL "$FTP/${RUN}_1.fastq.gz" -o test_data/sample1_R1.fastq.gz
curl -fsSL "$FTP/${RUN}_2.fastq.gz" -o test_data/sample1_R2.fastq.gz
D="docker run --rm -v $PWD/test_data:/data"
$D biocontainers/samtools:v1.9-4-deb_cv1 samtools faidx /data/reference.fasta
$D broadinstitute/gatk:4.5.0.0 gatk CreateSequenceDictionary -R /data/reference.fasta -O /data/reference.dict
$D biocontainers/bwa:v0.7.17_cv1 bwa index /data/reference.fasta
