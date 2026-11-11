# Running on HPC (SLURM) and AWS

Scripts and settings below were validated locally (see "What was verified").

Needs `test_data/` (FASTQs + indexed reference); supply it via S3 (EC2) or place it in the repo directory (HPC). See README for the layout.

## HPC (SLURM + Apptainer)

Uses the `slurm` profile in `nextflow.config` (Singularity/Apptainer
containers). Edit `process.queue` for your cluster, then:

```bash
mkdir -p logs && sbatch hpc/submit_slurm.sbatch
```

## AWS (single EC2 instance + S3)

One-shot instance: boots Amazon Linux 2023, installs Docker, clones this repo,
runs the analysis, syncs outputs to S3, then **terminates itself** (a
`shutdown -h +MAX_HOURS` dead-man switch also guards against hangs).

```bash
export S3_BUCKET=my-bucket          # existing bucket you can write to
export INSTANCE_PROFILE=my-ec2-role # IAM instance profile allowing s3:PutObject
./aws/launch_ec2.sh
```

Default instance `m6i.2xlarge` (100 GB gp3). Outputs land in
`s3://$S3_BUCKET/nf-variant-pipeline/<timestamp>/`, with `analysis.log`. Remember to
check cost for your instance type and region; nothing is created until you run
the script, and the instance stops billing when it terminates.

**Input data:** pass `INPUT_S3=s3://bucket/test_data/` to sync your FASTQs/reference into `test_data/`.

For managed scale-out, `nextflow.config` also has an `awsbatch` profile (fill in your own queue/bucket).

## What was verified

- Nextflow `-profile slurm` / `awsbatch` configs parse (`nextflow config`).
