# nf-variant-pipeline

A minimal, real, working Nextflow DSL2 pipeline for germline short-variant calling:

```
FASTQ  ->  BWA-MEM align  ->  Picard MarkDuplicates  ->  GATK HaplotypeCaller  ->  bcftools filter
                                      |
                                      v
                              samtools flagstat (QC)
```

This is a small-scale version of the kind of pipeline used behind targeted
clinical cancer panels (e.g. tumor-normal somatic calling workflows) — same
tools (BWA, GATK, samtools, bcftools), same shape, just simplified to
germline single-sample calling on toy data so it runs on a laptop in minutes.

## Why this project

Built specifically to go from "I know GATK/BWA/samtools/Docker individually"
to "I can build a real orchestrated pipeline with them in Nextflow" —
the exact gap between doing bioinformatics by hand and building the kind of
production pipeline infrastructure a clinical genomics bioinformatics role
actually needs day to day.

## Requirements

- [Nextflow](https://www.nextflow.io/docs/latest/install.html) (>=23.10.0)
- [Docker](https://docs.docker.com/get-docker/) (or Singularity — see `-profile singularity`)
- No local install of BWA/GATK/samtools/bcftools needed — every process
  pulls its own container image automatically.

## Getting test data

Don't use real/clinical data for this. Use a small public test slice —
the [nf-core/test-datasets](https://github.com/nf-core/test-datasets) repo
hosts small, purpose-built FASTQ/reference files exactly for pipeline
development like this. A convenient starting point is the `sarek` branch,
which has tiny paired-end FASTQs and a small reference already sized for
fast local runs.

Expected layout in `test_data/`:

```
test_data/
├── sample1_R1.fastq.gz
├── sample1_R2.fastq.gz
├── reference.fasta
├── reference.fasta.fai        # samtools faidx reference.fasta
├── reference.dict             # gatk CreateSequenceDictionary -R reference.fasta
├── reference.fasta.amb        # bwa index reference.fasta  (generates .amb/.ann/.bwt/.pac/.sa)
├── reference.fasta.ann
├── reference.fasta.bwt
├── reference.fasta.pac
└── reference.fasta.sa
```

Two one-time indexing commands you'll need to run on whatever reference
FASTA you use (via Docker, no local install needed):

```bash
docker run -v $PWD/test_data:/data biocontainers/samtools:v1.9-4-deb_cv1 \
    samtools faidx /data/reference.fasta

docker run -v $PWD/test_data:/data broadinstitute/gatk:4.5.0.0 \
    gatk CreateSequenceDictionary -R /data/reference.fasta

docker run -v $PWD/test_data:/data biocontainers/bwa:v0.7.17_cv1 \
    bwa index /data/reference.fasta
```

## Running it

```bash
nextflow run main.nf -profile docker
```

Override any parameter on the command line, e.g.:

```bash
nextflow run main.nf -profile docker \
    --reads 'test_data/*_R{1,2}.fastq.gz' \
    --reference test_data/reference.fasta \
    --outdir results
```

## The `-resume` exercise (do this — it's the actual point)

This is the single feature that most demonstrates real Nextflow
understanding, and it's easy to skip if you just run a pipeline once
top to bottom. Do this deliberately:

1. Run the pipeline normally: `nextflow run main.nf -profile docker`
2. While `HAPLOTYPE_CALLER` is running (or right after it finishes),
   kill the process with Ctrl-C.
3. Re-run the *exact same command*, but add `-resume`:
   `nextflow run main.nf -profile docker -resume`
4. Watch the log — completed processes (`BWA_ALIGN`, `MARK_DUPLICATES`)
   will show as `[cached]` and skip straight to re-running only the
   steps that didn't finish. Nothing is redone unnecessarily.

This works because Nextflow hashes each process's inputs and stores
results in `work/`, keyed by that hash — if inputs haven't changed,
it reuses the cached output instead of re-executing. This is exactly
what makes Nextflow useful for long, expensive clinical pipelines: a
failure on step 8 of 10 doesn't mean re-running steps 1-7.

## Pipeline execution reports

Every run automatically generates (via `nextflow.config`):
- `results/pipeline_info/execution_report.html` — resource usage per process
- `results/pipeline_info/execution_timeline.html` — visual Gantt-style timeline
- `results/pipeline_info/execution_trace.txt` — raw trace data

Open the HTML report after a run — it's genuinely useful for understanding
where time/memory actually goes, and worth mentioning in an interview as
something you use to optimize pipelines.

## What each profile is for

- `-profile docker` — local development, what you'll use day to day
- `-profile singularity` — HPC clusters that don't allow Docker (most don't,
  for security reasons) — this is likely what a real institutional HPC
  environment would require
- `-profile slurm` — example Slurm executor config for an HPC cluster
  (edit `queue`/`account` for a real cluster)
- `-profile awsbatch` — example cloud execution config (edit bucket/queue)

## Next steps to extend this

- Add variant annotation (VEP or ANNOVAR) as a process after `FILTER_VARIANTS`
- Convert to tumor-normal somatic calling with `Mutect2` instead of
  `HaplotypeCaller` — closer to what a clinical cancer panel pipeline does
- Split processes into `modules/` files (standard nf-core project layout)
  once the pipeline grows past a handful of processes
