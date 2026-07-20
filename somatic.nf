#!/usr/bin/env nextflow

/*
 * Somatic tumor-normal variant-calling pipeline
 * BWA-MEM -> MarkDuplicates -> Mutect2 (tumor-normal) -> FilterMutectCalls
 *   -> SnpEff annotation -> (optional) hap.py concordance vs. a truth set
 *
 * This mirrors the shape of a real clinical targeted-panel somatic
 * pipeline (e.g. tumor-normal matched calling as used by panels like
 * NYU Langone's Genome PACT), scaled down to small public test data.
 *
 * Reuses the germline pipeline's BWA_MEM / SORT_BAM / MARK_DUPLICATES
 * processes conceptually — each sample (tumor and normal) goes through
 * the same alignment + dedup steps before Mutect2 compares them.
 */

nextflow.enable.dsl = 2

// ---------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------
params.tumor_reads   = "$projectDir/test_data/tumor_R{1,2}.fastq.gz"
params.normal_reads  = "$projectDir/test_data/normal_R{1,2}.fastq.gz"
params.reference     = "$projectDir/test_data/reference.fasta"
params.snpeff_db     = "GRCh37.75"          // matches the GRCh37-based test_data/reference.fasta; adjust if you point --reference at a different build
params.truth_vcf     = ""                    // optional: path to a GIAB-style truth VCF for concordance
params.truth_bed     = ""                    // optional: high-confidence regions BED for the truth VCF
// params.outdir default (results_somatic) lives in nextflow.config (needed there before this script runs)

// ---------------------------------------------------------------------
// Shared alignment + dedup, parameterized by a "role" tag (tumor/normal)
// so the same two processes handle both samples.
// ---------------------------------------------------------------------
process ALIGN {
    tag "$role:$sample_id"
    container 'biocontainers/bwa:v0.7.17_cv1'

    input:
    tuple val(role), val(sample_id), path(reads)
    path reference
    path reference_index

    output:
    tuple val(role), val(sample_id), path("${sample_id}.sam"), emit: sam

    script:
    """
    bwa mem -t ${task.cpus} -R "@RG\\tID:${sample_id}\\tSM:${sample_id}\\tPL:ILLUMINA" \\
        "${reference}" "${reads[0]}" "${reads[1]}" > "${sample_id}.sam"
    """
}

process SORT_AND_DEDUP {
    tag "$role:$sample_id"
    container 'broadinstitute/gatk:4.5.0.0'
    publishDir "${params.outdir}/dedup", mode: 'copy'

    input:
    tuple val(role), val(sample_id), path(sam)

    output:
    tuple val(role), val(sample_id), path("${sample_id}.dedup.bam"), path("${sample_id}.dedup.bam.bai"), emit: bam

    script:
    """
    samtools sort -@ ${task.cpus} -o "${sample_id}.sorted.bam" "${sam}"

    gatk MarkDuplicates \\
        -I "${sample_id}.sorted.bam" \\
        -O "${sample_id}.dedup.bam" \\
        -M "${sample_id}.dedup.metrics.txt"

    samtools index "${sample_id}.dedup.bam"
    """
}

// ---------------------------------------------------------------------
// Mutect2 — tumor-normal matched somatic calling
// ---------------------------------------------------------------------
process MUTECT2 {
    tag "$tumor_id vs $normal_id"
    container 'broadinstitute/gatk:4.5.0.0'
    publishDir "${params.outdir}/mutect2", mode: 'copy'
    cpus 4
    memory '8 GB'

    input:
    tuple val(tumor_id), path(tumor_bam), path(tumor_bai)
    tuple val(normal_id), path(normal_bam), path(normal_bai)
    path reference
    path reference_dict
    path reference_fai

    output:
    tuple val(tumor_id), path("${tumor_id}_vs_${normal_id}.unfiltered.vcf.gz"),
                          path("${tumor_id}_vs_${normal_id}.unfiltered.vcf.gz.tbi"),
                          path("${tumor_id}_vs_${normal_id}.unfiltered.vcf.gz.stats"), emit: raw

    script:
    """
    gatk Mutect2 \\
        -R "${reference}" \\
        -I "${tumor_bam}"  -tumor  "${tumor_id}" \\
        -I "${normal_bam}" -normal "${normal_id}" \\
        -O "${tumor_id}_vs_${normal_id}.unfiltered.vcf.gz"
    """
}

// ---------------------------------------------------------------------
// FilterMutectCalls — turns raw Mutect2 calls into PASS/FAIL genotyped calls
// ---------------------------------------------------------------------
process FILTER_MUTECT_CALLS {
    tag "$tumor_id"
    container 'broadinstitute/gatk:4.5.0.0'
    publishDir "${params.outdir}/mutect2_filtered", mode: 'copy'

    input:
    tuple val(tumor_id), path(vcf), path(tbi), path(stats)
    path reference
    path reference_dict
    path reference_fai

    output:
    tuple val(tumor_id), path("${tumor_id}.filtered.vcf.gz"), path("${tumor_id}.filtered.vcf.gz.tbi"), emit: vcf

    script:
    """
    gatk FilterMutectCalls \\
        -R "${reference}" \\
        -V "${vcf}" \\
        -O "${tumor_id}.filtered.vcf.gz"
    """
}

// ---------------------------------------------------------------------
// SnpEff — variant annotation (raw call -> something a pathologist can read)
// Pinned to 5.3 (not 5.2): snpEff <=5.2's database download defaults to
// snpeff.blob.core.windows.net, an Azure storage host Microsoft has since
// decommissioned (dead for every snpEff <=5.2 user, not an issue specific to
// this environment) — 5.3+ downloads from a working host.
//
// KNOWN LIMITATION (see SOMATIC.md "Known limitations"): even 5.3's working
// host was unreachable from the environment this was built in (network/WAF
// block, not a code issue). This process is correctly written and will run
// wherever the SnpEff database host is reachable — it just hasn't been
// exercised end-to-end here. In a real deployment the database would be
// fetched once and cached centrally rather than pulled per run.
// ---------------------------------------------------------------------
process SNPEFF_ANNOTATE {
    tag "$tumor_id"
    container 'quay.io/biocontainers/snpeff:5.3.0a--hdfd78af_1'
    publishDir "${params.outdir}/annotated", mode: 'copy', pattern: '*.snpeff_summary.html'

    input:
    tuple val(tumor_id), path(vcf), path(tbi)

    output:
    tuple val(tumor_id), path("${tumor_id}.annotated.vcf"), emit: vcf
    path "${tumor_id}.snpeff_summary.html",                 emit: report

    script:
    """
    snpEff -Xmx4g "${params.snpeff_db}" "${vcf}" \\
        -stats "${tumor_id}.snpeff_summary.html" \\
        > "${tumor_id}.annotated.vcf"
    """
}

// ---------------------------------------------------------------------
// bgzip the annotated VCF — split out from SNPEFF_ANNOTATE because the
// snpEff container doesn't bundle bgzip (same reason BWA_MEM/SORT_BAM are
// split in main.nf: each process gets the one container that actually has
// its tool).
// ---------------------------------------------------------------------
process COMPRESS_ANNOTATED_VCF {
    tag "$tumor_id"
    container 'quay.io/biocontainers/htslib:1.24--ha79157c_0'
    publishDir "${params.outdir}/annotated", mode: 'copy'

    input:
    tuple val(tumor_id), path(vcf)

    output:
    tuple val(tumor_id), path("${tumor_id}.annotated.vcf.gz"), emit: vcf

    script:
    """
    bgzip -c "${vcf}" > "${tumor_id}.annotated.vcf.gz"
    """
}

// ---------------------------------------------------------------------
// hap.py — benchmark filtered calls against a GIAB-style truth set
// Only runs if params.truth_vcf is set; this is what turns "a pipeline
// that runs" into "a pipeline with a documented sensitivity/specificity
// validation", the language the job posting explicitly uses.
// ---------------------------------------------------------------------
process CONCORDANCE {
    tag "$tumor_id"
    container 'pkrusche/hap.py:latest'  // consider repinning to a specific digest before real use
    publishDir "${params.outdir}/concordance", mode: 'copy'

    input:
    tuple val(tumor_id), path(query_vcf), path(query_tbi)
    path truth_vcf
    path truth_bed
    path reference
    path reference_fai

    output:
    path "${tumor_id}_happy.summary.csv"

    script:
    """
    hap.py \\
        "${truth_vcf}" \\
        "${query_vcf}" \\
        -f "${truth_bed}" \\
        -r "${reference}" \\
        -o "${tumor_id}_happy"
    """
}

// ---------------------------------------------------------------------
// sample_id is interpolated directly into shell commands in every process
// (read-group strings, output filenames), so it's restricted to a safe
// charset here to prevent shell injection via a maliciously named input
// file. Defined as a top-level function (not a closure-typed local var)
// so it resolves correctly when called from inside a Channel .map{} closure.
// ---------------------------------------------------------------------
def validate_id(sample_id) {
    if (!(sample_id ==~ /^[A-Za-z0-9_.-]+$/)) {
        error "Unsafe sample_id '${sample_id}' — must match ^[A-Za-z0-9_.-]+\$"
    }
    sample_id
}

// ---------------------------------------------------------------------
// Workflow
// ---------------------------------------------------------------------
workflow {
    log.info """
             SOMATIC TUMOR-NORMAL PIPELINE
             ==============================
             tumor_reads  : ${params.tumor_reads}
             normal_reads : ${params.normal_reads}
             reference    : ${params.reference}
             truth_vcf    : ${params.truth_vcf ?: '(none — concordance step will be skipped)'}
             outdir       : ${params.outdir}
             """
             .stripIndent()

    // .first()/.collect() turn these into reusable "value channels" — without
    // that, a plain Channel.fromPath emits its one file, closes, and is
    // exhausted after being paired with the first process invocation, so
    // any sample after the first (e.g. "normal" here, since tumor+normal
    // both flow through ALIGN/SORT_AND_DEDUP) silently never runs.
    reference_ch       = Channel.fromPath(params.reference, checkIfExists: true).first()
    reference_index_ch = Channel.fromPath("${params.reference}.{amb,ann,bwt,pac,sa}", checkIfExists: true).collect()
    reference_dict_ch  = Channel.fromPath(params.reference.replace('.fasta', '.dict'), checkIfExists: true).first()
    reference_fai_ch   = Channel.fromPath("${params.reference}.fai", checkIfExists: true).first()

    tumor_ch = Channel
        .fromFilePairs(params.tumor_reads, checkIfExists: true)
        .map { sample_id, reads -> tuple('tumor', validate_id(sample_id), reads) }

    normal_ch = Channel
        .fromFilePairs(params.normal_reads, checkIfExists: true)
        .map { sample_id, reads -> tuple('normal', validate_id(sample_id), reads) }

    reads_ch = tumor_ch.mix(normal_ch)

    ALIGN(reads_ch, reference_ch, reference_index_ch)
    SORT_AND_DEDUP(ALIGN.out.sam)

    // Split back into tumor/normal channels for Mutect2's paired input
    tumor_bam_ch  = SORT_AND_DEDUP.out.bam.filter { role, id, bam, bai -> role == 'tumor'  }.map { role, id, bam, bai -> tuple(id, bam, bai) }
    normal_bam_ch = SORT_AND_DEDUP.out.bam.filter { role, id, bam, bai -> role == 'normal' }.map { role, id, bam, bai -> tuple(id, bam, bai) }

    MUTECT2(tumor_bam_ch, normal_bam_ch, reference_ch, reference_dict_ch, reference_fai_ch)
    FILTER_MUTECT_CALLS(MUTECT2.out.raw, reference_ch, reference_dict_ch, reference_fai_ch)
    SNPEFF_ANNOTATE(FILTER_MUTECT_CALLS.out.vcf)
    COMPRESS_ANNOTATED_VCF(SNPEFF_ANNOTATE.out.vcf)

    if (params.truth_vcf) {
        truth_vcf_ch = Channel.fromPath(params.truth_vcf, checkIfExists: true)
        truth_bed_ch = Channel.fromPath(params.truth_bed, checkIfExists: true)
        CONCORDANCE(FILTER_MUTECT_CALLS.out.vcf, truth_vcf_ch, truth_bed_ch, reference_ch, reference_fai_ch)
    } else {
        log.info "No --truth_vcf provided — skipping concordance benchmarking step."
    }
}
