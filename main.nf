#!/usr/bin/env nextflow

/*
 * Minimal germline variant-calling pipeline
 * BWA-MEM -> Picard MarkDuplicates -> GATK HaplotypeCaller -> bcftools filter
 *
 * This mirrors (at small scale) the kind of pipeline used in clinical
 * targeted-panel variant calling (e.g. Genome PACT / Oncomine style workflows).
 */

nextflow.enable.dsl = 2

// ---------------------------------------------------------------------
// Parameters (override any of these on the command line with --paramName)
// ---------------------------------------------------------------------
params.reads      = "$projectDir/test_data/*_R{1,2}.fastq.gz"  // paired-end FASTQs
params.reference  = "$projectDir/test_data/reference.fasta"     // reference genome FASTA
// params.outdir default lives in nextflow.config (needed there before this script runs)

// ---------------------------------------------------------------------
// Process 1a: Align reads with BWA-MEM
// ---------------------------------------------------------------------
process BWA_MEM {
    tag "$sample_id"
    container 'biocontainers/bwa:v0.7.17_cv1'

    input:
    tuple val(sample_id), path(reads)
    path reference
    path reference_index // .amb .ann .bwt .pac .sa (bwa index files)

    output:
    tuple val(sample_id), path("${sample_id}.sam"), emit: sam

    script:
    """
    bwa mem -t ${task.cpus} -R '@RG\\tID:${sample_id}\\tSM:${sample_id}\\tPL:ILLUMINA' \\
        "${reference}" "${reads[0]}" "${reads[1]}" \\
        > "${sample_id}.sam"
    """
}

// ---------------------------------------------------------------------
// Process 1b: Sort alignment with samtools
// ---------------------------------------------------------------------
process SORT_BAM {
    tag "$sample_id"
    container 'quay.io/biocontainers/samtools:1.9--h91753b0_8'
    publishDir "${params.outdir}/aligned", mode: 'copy'

    input:
    tuple val(sample_id), path(sam)

    output:
    tuple val(sample_id), path("${sample_id}.sorted.bam"), emit: bam

    script:
    """
    samtools sort -@ ${task.cpus} -o "${sample_id}.sorted.bam" "${sam}"
    """
}

// ---------------------------------------------------------------------
// Process 2: Mark duplicates with Picard (via GATK container, which bundles it)
// ---------------------------------------------------------------------
process MARK_DUPLICATES {
    tag "$sample_id"
    container 'broadinstitute/gatk:4.5.0.0'
    publishDir "${params.outdir}/dedup", mode: 'copy'

    input:
    tuple val(sample_id), path(bam)

    output:
    tuple val(sample_id), path("${sample_id}.dedup.bam"), emit: bam
    path "${sample_id}.dedup.metrics.txt",                emit: metrics

    script:
    """
    gatk MarkDuplicates \\
        -I "${bam}" \\
        -O "${sample_id}.dedup.bam" \\
        -M "${sample_id}.dedup.metrics.txt"

    samtools index "${sample_id}.dedup.bam"
    """
}

// ---------------------------------------------------------------------
// Process 3: Call variants with GATK HaplotypeCaller
// ---------------------------------------------------------------------
process HAPLOTYPE_CALLER {
    tag "$sample_id"
    container 'broadinstitute/gatk:4.5.0.0'
    publishDir "${params.outdir}/variants", mode: 'copy'

    input:
    tuple val(sample_id), path(bam)
    path reference
    path reference_dict
    path reference_fai

    output:
    tuple val(sample_id), path("${sample_id}.raw.vcf.gz"), emit: vcf

    script:
    """
    gatk HaplotypeCaller \\
        -R "${reference}" \\
        -I "${bam}" \\
        -O "${sample_id}.raw.vcf.gz"
    """
}

// ---------------------------------------------------------------------
// Process 4: Basic quality filtering with bcftools
// ---------------------------------------------------------------------
process FILTER_VARIANTS {
    tag "$sample_id"
    container 'quay.io/biocontainers/bcftools:1.9--h68d8f2e_9'
    publishDir "${params.outdir}/filtered", mode: 'copy'

    input:
    tuple val(sample_id), path(vcf)

    output:
    tuple val(sample_id), path("${sample_id}.filtered.vcf.gz"), emit: vcf
    path "${sample_id}.filtered.vcf.gz.tbi",                    emit: tbi

    script:
    """
    bcftools filter \\
        -e 'QUAL<30 || INFO/DP<10' \\
        -O z -o "${sample_id}.filtered.vcf.gz" \\
        "${vcf}"

    bcftools index -t "${sample_id}.filtered.vcf.gz"
    """
}

// ---------------------------------------------------------------------
// Process 5: QC metrics with samtools flagstat
// ---------------------------------------------------------------------
process FLAGSTAT {
    tag "$sample_id"
    container 'quay.io/biocontainers/samtools:1.9--h91753b0_8'
    publishDir "${params.outdir}/qc", mode: 'copy'

    input:
    tuple val(sample_id), path(bam)

    output:
    path "${sample_id}.flagstat.txt"

    script:
    """
    samtools flagstat "${bam}" > "${sample_id}.flagstat.txt"
    """
}

// ---------------------------------------------------------------------
// Workflow
// ---------------------------------------------------------------------
workflow {
    log.info """
             VARIANT-CALLING PIPELINE
             =========================
             reads      : ${params.reads}
             reference  : ${params.reference}
             outdir     : ${params.outdir}
             """
             .stripIndent()

    // Build [sample_id, [read1, read2]] tuples from the glob pattern
    // sample_id is interpolated directly into shell commands in every downstream
    // process (e.g. bwa's -R read-group string, output filenames), so it's
    // restricted to a safe charset here to prevent shell injection via a
    // maliciously named input file.
    read_pairs_ch = Channel
        .fromFilePairs(params.reads, checkIfExists: true)
        .map { sample_id, reads ->
            if (!(sample_id ==~ /^[A-Za-z0-9_.-]+$/)) {
                error "Unsafe sample_id '${sample_id}' derived from input filename: only letters, numbers, '.', '_', '-' are allowed."
            }
            [sample_id, reads]
        }

    reference_ch       = Channel.fromPath(params.reference, checkIfExists: true)
    reference_index_ch = Channel.fromPath("${params.reference}.{amb,ann,bwt,pac,sa}", checkIfExists: true).collect()
    reference_dict_ch  = Channel.fromPath(params.reference.replace('.fasta', '.dict'), checkIfExists: true)
    reference_fai_ch   = Channel.fromPath("${params.reference}.fai", checkIfExists: true)

    BWA_MEM(read_pairs_ch, reference_ch, reference_index_ch)
    SORT_BAM(BWA_MEM.out.sam)
    MARK_DUPLICATES(SORT_BAM.out.bam)
    FLAGSTAT(MARK_DUPLICATES.out.bam)
    HAPLOTYPE_CALLER(MARK_DUPLICATES.out.bam, reference_ch, reference_dict_ch, reference_fai_ch)
    FILTER_VARIANTS(HAPLOTYPE_CALLER.out.vcf)
}
