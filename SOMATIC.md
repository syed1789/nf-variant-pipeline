# Somatic tumor-normal extension (`somatic.nf`)

Extends the germline pipeline in this repo with a **tumor-normal matched
somatic** variant-calling workflow — the shape of pipeline used behind
real clinical cancer panels (e.g. tumor-normal matched NGS panels like
NYU Langone's Genome PACT), rather than the single-sample germline
calling `main.nf` does.

```
tumor  FASTQ  ─┐
               ├─> BWA-MEM ─> sort ─> MarkDuplicates ─┐
normal FASTQ  ─┘                                       ├─> Mutect2 (paired)
                                                        │
                                            FilterMutectCalls
                                                        │
                                            SnpEff annotation
                                                        │
                                    (optional) hap.py concordance vs. truth set
```

## Why this exists

The germline pipeline demonstrates the mechanics of Nextflow + the
variant-calling toolchain. This extension demonstrates the specific
thing a clinical genomics bioinformatics role actually needs: **paired
tumor-normal somatic calling, annotation, and — critically — a
documented validation step (concordance against a truth set)**, which
is explicitly what "variant calling benchmarking and clinical
validation analysis (concordance, limit of detection, assay
reproducibility)" means in practice.

## Getting test data

Same principle as the germline pipeline: use small public data, never
real/clinical samples.

- **Tumor-normal FASTQs**: the `nf-core/test-datasets` `sarek` branch
  includes small tumor/normal test pairs specifically built for this
  kind of pipeline development.
- **Truth set (optional but recommended)**: the Genome in a Bottle
  (GIAB) consortium's **SEQC2 / HCC1395-HCC1395BL** tumor-normal cell
  line pair is the standard public benchmark for somatic calling
  validation — it has a well-characterized "truth" somatic call set
  and high-confidence regions BED file. For a small local demo, use a
  chromosome-restricted subset (e.g. just chr20 or chr21) rather than
  the full genome, to keep runtime and file size reasonable.
- If you don't have a truth VCF, the pipeline still runs — `--truth_vcf`
  is optional, and the concordance step is skipped with a clear log
  message rather than failing.

## Running it

```bash
nextflow run somatic.nf -profile docker \
    --tumor_reads  'test_data/tumor_R{1,2}.fastq.gz' \
    --normal_reads 'test_data/normal_R{1,2}.fastq.gz' \
    --reference    test_data/reference.fasta \
    --snpeff_db    GRCh38.99
```

With concordance benchmarking against a truth set:

```bash
nextflow run somatic.nf -profile docker \
    --tumor_reads  'test_data/tumor_R{1,2}.fastq.gz' \
    --normal_reads 'test_data/normal_R{1,2}.fastq.gz' \
    --reference    test_data/reference.fasta \
    --truth_vcf    test_data/giab_truth.chr20.vcf.gz \
    --truth_bed    test_data/giab_confident_regions.chr20.bed
```

## Reading the concordance output

`hap.py` produces a summary CSV with, at minimum, **sensitivity
(recall)** and **precision** for SNPs and indels separately — the same
metrics a real clinical validation report would cite. This is the
single most interview-relevant artifact in this extension: it's proof
of understanding *why* a pipeline needs validation, not just that it
can call variants.

## Security notes specific to this extension

- Same `sample_id` allowlist validation (`^[A-Za-z0-9_.-]+$`) applied
  at the channel boundary, for both tumor and normal inputs
  independently.
- `pkrusche/hap.py:latest` is used as a placeholder — **before using
  this for anything beyond a one-off local demo, repin it to a
  specific digest**, consistent with how the germline pipeline's
  containers were repinned during its security review. `:latest` tags
  are a reproducibility and supply-chain risk, not just a style
  preference.
- No real patient/tumor data — GIAB's HCC1395/HCC1395BL is a public,
  consented, widely-used reference cell-line pair specifically
  released for benchmarking purposes, not patient data.

## Known limitations

### SnpEff annotation is not runnable out of the box right now

SnpEff's built-in database downloader defaults to
`snpeff.blob.core.windows.net` for SnpEff <=5.2 — a Microsoft Azure
storage endpoint that has since been decommissioned. This is confirmed
via multiple upstream GitHub issues against the SnpEff project itself,
not specific to any one environment or network. This pipeline is
pinned to SnpEff 5.3 (`quay.io/biocontainers/snpeff:5.3.0a--hdfd78af_1`),
which correctly points at a newer host
(`snpeff.odsp.astrazeneca.com`) — but in the environment this was
built and tested in, that host returned a CloudFront "Request
blocked" (403) response for every database tested, consistent with a
network/WAF-level access restriction rather than a problem with the
pipeline code itself.

A working alternative source was found on SourceForge (an older,
v4.3-era build of the GRCh37.75 database, which remains loadable by
newer SnpEff versions) — but at ~694 MB for a toy reference that's
essentially an N-padded chr1 fragment with negligible real gene
content, it wasn't worth pulling down for this demo's actual
annotation value.

**In a real institutional deployment**, this database would be
fetched once and cached centrally (shared storage, or baked into a
custom container image) rather than re-downloaded on every pipeline
run — that's standard practice specifically because public annotation
database hosts aren't reliably available on demand.

`SNPEFF_ANNOTATE` and `COMPRESS_ANNOTATED_VCF` are left in the
pipeline as written; they're correctly configured (correct tool
version, and annotation is split from bgzip since the SnpEff
container doesn't bundle it) and will run successfully wherever the
SnpEff database host is reachable.

### Concordance benchmarking needs matched data, not just a truth set

The GIAB/SEQC2 HCC1395/HCC1395BL high-confidence truth files
themselves are small (~4.8 MB VCF + 16 MB BED, whole-genome — no
chromosome restriction even required) — file size is not the
obstacle. The obstacle is that this truth set encodes **real**
HCC1395/HCC1395BL variant positions, while the tumor/normal reads
used in this demo (nf-core's synthetic `dummy_t`/`dummy_n` test data)
have no relationship to that cell line.

Running `hap.py` concordance with these inputs would execute without
error and produce a summary CSV — but the resulting sensitivity/
precision numbers would be scientifically meaningless (effectively
zero true positives), not because the pipeline calls variants poorly,
but because the query calls and the truth set describe unrelated
genomes. Presenting those numbers as if they were a real validation
result would be misleading.

A genuine concordance demo would require real, matched
HCC1395/HCC1395BL sequencing reads (available via SRA, e.g. BioProject
PRJNA201238), restricted to a small region and aligned — a separate,
larger undertaking than fetching a small truth file. Noted here as
documented future work, not something to fake with mismatched data.

## Debugging notes: silent-failure bugs found while building this

Three bugs surfaced while getting this pipeline running end to end,
and they're worth documenting explicitly because none of them caused
an error — the pipeline reported `[SUCCESS]` in every case, while
quietly doing the wrong thing. In a clinical pipeline that's the
dangerous failure mode: an obvious crash gets noticed and fixed, a
quiet wrong answer doesn't.

**1. Reference channels silently exhausted after the first sample.**
`reference_ch`, `reference_dict_ch`, and `reference_fai_ch` were built
with a plain `Channel.fromPath(...)` — which emits its one file, then
closes. Paired against a process invoked once per sample (tumor *and*
normal both flow through `ALIGN`/`SORT_AND_DEDUP`), the first sample
consumed that channel's only value; every subsequent sample simply
never fired, because Nextflow had nothing left to pair it with. No
error, no warning — just a process that silently ran once instead of
twice, with `[SUCCESS] completed=2` on a run that should have
completed 7 processes for 2 samples. Fixed with `.first()`, which
turns these into reusable "value channels."

**2. The identical bug was already latent in `main.nf`.** The
germline pipeline had the exact same pattern in its own reference
channels — invisible for months because it only ever processed one
sample. Adding `tumor_R*`/`normal_R*` fastqs to the same `test_data/`
directory this session widened `main.nf`'s own glob
(`*_R{1,2}.fastq.gz`) enough to accidentally match all three sample
groups, which triggered the same silent-drop behavior in the germline
pipeline too — it quietly processed only `tumor` and still reported
success. Both the glob and the channel reuse were fixed in `main.nf`
as a direct result of building this extension.

**3. Shared `nextflow.config`, colliding output directories.**
`main.nf` and `somatic.nf` share one `nextflow.config` in this repo.
Config-set params always take precedence over a script's own
`params.x = ...` assignment (documented Nextflow behavior, not a bug
in Nextflow itself) — so `somatic.nf`'s intended `results_somatic`
default was silently overridden by the germline `results` default set
in the shared config, and a somatic run wrote its output (and
overwrote `main.nf`'s own `execution_trace.txt`) directly into
`main.nf`'s results directory. Fixed by branching the config's outdir
default on whether `--tumor_reads` was supplied — a param only the
somatic pipeline ever sets — so each pipeline gets its own output root
without requiring an extra `--outdir` flag on the command line.

None of these were caught by the pipelines "running successfully" —
they were caught by comparing what *should* have been produced
against what actually was, which is exactly the validation discipline
a clinical pipeline needs.

## Talking points this gives you for an interview

- You can explain the *difference* between germline (`main.nf`,
  single-sample HaplotypeCaller) and somatic (`somatic.nf`,
  tumor-normal Mutect2) calling, and why they're different problems —
  somatic calling has to distinguish true tumor-specific mutations
  from germline variants shared with the matched normal, which is why
  Mutect2 needs both BAMs simultaneously rather than calling each
  sample independently.
- You understand why `FilterMutectCalls` is a separate step from
  `Mutect2` itself (Mutect2 emits candidate calls; filtering applies
  statistical/technical filters — like sequencing artifacts and low
  allele fraction — before calls are considered final).
- You can speak concretely to concordance/sensitivity/precision as
  real numbers from a real (if small) run, not just as vocabulary.
