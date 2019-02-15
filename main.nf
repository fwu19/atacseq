#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/atacseq
========================================================================================
 nf-core/atacseq Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/atacseq
----------------------------------------------------------------------------------------
*/

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                             PARAMETERS                              -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

def helpMessage() {
    log.info nfcoreHeader()
    log.info"""
    Usage:

    The typical command for running the pipeline is as follows:

      nextflow run nf-core/atacseq --design design.csv --genome GRCh37 -profile docker

    Mandatory arguments:
      --design                      Comma-separted file containing information about the samples in the experiment (see docs/usage.md)
      --fasta                       Path to Fasta reference. Not mandatory when using reference in iGenomes config via --genome
      --gtf                         Path to GTF file in Ensembl format. Not mandatory when using reference in iGenomes config via --genome
      -profile                      Configuration profile to use. Can use multiple (comma separated)
                                    Available: conda, docker, singularity, awsbatch, test

    Generic
      --genome                      Name of iGenomes reference
      --singleEnd                   Specifies that the input is single-end reads
      --narrowPeak                  Run MACS in narrowPeak mode. Default: broadPeak
      --fragment_size [int]         Estimated fragment size used to extend single-end reads. Default: 0
      --bwa_aln                     Use bwa aln algorithm as opposed to bwa mem for mapping reads

    References                      If not specified in the configuration file or you wish to overwrite any of the references
      --bwa_index_dir               Directory containing BWA index
      --bwa_index_base              Basename for BWA index. Default: genome.fa
      --gene_bed                    Path to BED file containing gene intervals
      --tss_bed                     Path to BED file containing transcription start sites (used by ataqv)
      --mito_name                   Name of Mitochondrial chomosome in genome fasta (e.g. chrM). Reads aligning to this contig are filtered out

      --macs_gsize                  Effective genome size parameter required by MACS2. If using iGenomes config, values have only been provided when --genome is set as GRCh37, GRCm38, hg19, mm10, BDGP6 and WBcel235
      --blacklist                   Path to blacklist regions (.BED format), used for filtering alignments
      --saveReference               Save the generated reference files in the Results directory

    Trimming
      --clip_r1 [int]               Instructs Trim Galore to remove bp from the 5' end of read 1 (or single-end reads)
      --clip_r2 [int]               Instructs Trim Galore to remove bp from the 5' end of read 2 (paired-end reads only)
      --three_prime_clip_r1 [int]   Instructs Trim Galore to remove bp from the 3' end of read 1 AFTER adapter/quality trimming has been performed
      --three_prime_clip_r2 [int]   Instructs Trim Galore to re move bp from the 3' end of read 2 AFTER adapter/quality trimming has been performed
      --skipTrimming                Skip the adapter trimming step
      --saveTrimmed                 Save the trimmed FastQ files in the the Results directory

    Alignments
      --keepMito                    Reads mapping to mitochondrial contig are not filtered from alignments
      --keepDups                    Duplicate reads are not filtered from alignments
      --keepMultiMap                Reads mapping to multiple locations are not filtered from alignments
      --skipMergeReplicates         Do not perform alignment merging and downstream analysis by merging replicates i.e. only do this at the library-level
      --saveAlignedIntermediates    Save the intermediate BAM files from the alignment step - not done by default

    Other
      --outdir                      The output directory where the results will be saved
      --email                       Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic

    AWSBatch
      --awsqueue                    The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion                   The AWS Region for your AWS Batch job to run on
    """.stripIndent()
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                SET UP CONFIGURATION VARIABLES                       -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Show help message
if (params.help){
    helpMessage()
    exit 0
}

// Check if genome exists in the config file
if (params.genomes && params.genome && !params.genomes.containsKey(params.genome)) {
    exit 1, "The provided genome '${params.genome}' is not available in the iGenomes file. Currently the available genomes are ${params.genomes.keySet().join(", ")}"
}

////////////////////////////////////////////////////
/* --         DEFAULT PARAMETER VALUES         -- */
////////////////////////////////////////////////////

// Configurable variables
params.fasta = params.genome ? params.genomes[ params.genome ].fasta ?: false : false
params.bwa_index_dir = params.genome ? params.genomes[ params.genome ].bwa ?: false : false
params.gtf = params.genome ? params.genomes[ params.genome ].gtf ?: false : false
params.gene_bed = params.genome ? params.genomes[ params.genome ].gene_bed ?: false : false
params.mito_name = params.genome ? params.genomes[ params.genome ].mito_name ?: false : false
params.macs_gsize = params.genome ? params.genomes[ params.genome ].macs_gsize ?: false : false
params.blacklist = params.genome ? params.genomes[ params.genome ].blacklist ?: false : false

// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
  custom_runName = workflow.runName
}

////////////////////////////////////////////////////
/* --          CONFIG FILES                    -- */
////////////////////////////////////////////////////

// Pipeline config
output_docs_ch = Channel.fromPath("$baseDir/docs/output.md", checkIfExists: true)

// JSON files required for BAMTools for alignment filtering
bamtools_filter_pe_config_ch = Channel.fromPath(params.bamtools_filter_pe_config, checkIfExists: true)
bamtools_filter_se_config_ch = Channel.fromPath(params.bamtools_filter_se_config, checkIfExists: true)

// Header files for MultiQC
multiqc_config_ch = Channel.fromPath(params.multiqc_config, checkIfExists: true)
mlib_peak_count_header_ch = Channel.fromPath("$baseDir/assets/multiqc/mlib_peak_count_header.txt", checkIfExists: true)
mlib_frip_score_header_ch = Channel.fromPath("$baseDir/assets/multiqc/mlib_frip_score_header.txt", checkIfExists: true)
mlib_peak_annotation_header_ch = Channel.fromPath("$baseDir/assets/multiqc/mlib_peak_annotation_header.txt", checkIfExists: true)
mlib_deseq2_pca_header_ch = Channel.fromPath("$baseDir/assets/multiqc/mlib_deseq2_pca_header.txt", checkIfExists: true)
mlib_deseq2_clustering_header_ch = Channel.fromPath("$baseDir/assets/multiqc/mlib_deseq2_clustering_header.txt", checkIfExists: true)

mrep_peak_count_header_ch = Channel.fromPath("$baseDir/assets/multiqc/mrep_peak_count_header.txt", checkIfExists: true)
mrep_frip_score_header_ch = Channel.fromPath("$baseDir/assets/multiqc/mrep_frip_score_header.txt", checkIfExists: true)
mrep_peak_annotation_header_ch = Channel.fromPath("$baseDir/assets/multiqc/mrep_peak_annotation_header.txt", checkIfExists: true)
mrep_deseq2_pca_header_ch = Channel.fromPath("$baseDir/assets/multiqc/mrep_deseq2_pca_header.txt", checkIfExists: true)
mrep_deseq2_clustering_header_ch = Channel.fromPath("$baseDir/assets/multiqc/mrep_deseq2_clustering_header.txt", checkIfExists: true)

////////////////////////////////////////////////////
/* --          VALIDATE INPUTS                 -- */
////////////////////////////////////////////////////

// Validate inputs
if( params.fasta ){
    Channel
        .fromPath(params.fasta, checkIfExists: true)
        .ifEmpty { exit 1, "Fasta file not found: ${params.fasta}" }
        .into { fasta_bwa_index;
                fasta_genome_filter;
                fasta_markdup_metrics;
                fasta_mlib_metrics;
                fasta_mlib_macs_annotate;
                fasta_mlib_macs_consensus_annotate;
                fasta_mrep_macs_annotate;
                fasta_mrep_macs_consensus_annotate }
} else {
    exit 1, "Fasta file not specified!"
}

if( params.gtf ){
    Channel
        .fromPath(params.gtf, checkIfExists: true)
        .ifEmpty { exit 1, "GTF annotation file not found: ${params.gtf}" }
        .into { gtf_gene_bed;
                gtf_mlib_macs_annotate;
                gtf_mlib_macs_consensus_annotate;
                gtf_mrep_macs_annotate;
                gtf_mrep_macs_consensus_annotate }
} else {
    exit 1, "GTF annotation file not specified!"
}

if( params.bwa_index_dir ){
    Channel
        .fromPath(params.bwa_index_dir, checkIfExists: true)
        .ifEmpty { exit 1, "BWA index not found: ${params.bwa_index_dir}" }
        .into { bwa_index_read1;
                bwa_index_read2;
                bwa_index_sai_to_sam }
}

if( params.gene_bed ){
    gene_bed = Channel
        .fromPath(params.gene_bed, checkIfExists: true)
        .ifEmpty { exit 1, "Gene BED annotation file not found: ${params.gene_bed}" }
}

if( params.tss_bed ){
    tss_bed = Channel
        .fromPath(params.tss_bed, checkIfExists: true)
        .ifEmpty { exit 1, "TSS BED annotation file not found: ${params.tss_bed}" }
}

if ( params.blacklist ) {
    blacklist = Channel
        .fromPath(params.blacklist, checkIfExists: true)
        .ifEmpty { exit 1, "Blacklist file not found: ${params.blacklist}" }
}

/*
 * Create a channel for input read files
 */
if( params.design ){
    if ( params.singleEnd ) {
        Channel
            .fromPath(params.design, checkIfExists: true)
            .ifEmpty { exit 1, "Samples design file not found: ${params.design}" }
            .splitCsv(header:true, sep:',')
            .map { row -> [ [row.group,"R"+row.replicate].join("_"),
                            [file(row.fastq_1)] ] }
            .groupTuple(by: [0])
            .map { group -> (1..group[1].size()).collect { value -> [ [ group[0],value ].join("_T"), group[1][value-1] ] } }
            .flatten()
            .collate( 2 )
            .map { it -> [ it[0], [ it[1] ] ] }
            .into { design_replicates_exist;
                    design_multiple_samples;
                    raw_reads_fastqc;
                    raw_reads_trimgalore }
    } else {
      Channel
          .fromPath(params.design, checkIfExists: true)
          .ifEmpty { exit 1, "Samples design file not found: ${params.design}" }
          .splitCsv(header:true, sep:',')
          .map { row -> [ [row.group,"R"+row.replicate].join("_"),
                          [file(row.fastq_1), file(row.fastq_2)] ] }
          .groupTuple(by: [0])
          .map { group -> (1..group[1].size()).collect { value -> [ [ group[0],value ].join("_T"), group[1][value-1] ] } }
          .flatten()
          .collate( 3 )
          .map { it -> [ it[0], [ it[1], it[2] ] ] }
          .into { design_replicates_exist;
                  design_multiple_samples;
                  raw_reads_fastqc;
                  raw_reads_trimgalore }
    }
} else {
    exit 1, "Samples design file not specified!"
}

// Boolean value for replicates existing in design
replicates_exist = design_replicates_exist.map { it -> it[0][-4].toInteger() }
                                          .flatten()
                                          .max()
                                          .val > 1

// Boolean value for multiple samples existing in design
multiple_samples = design_multiple_samples.map { it -> it[0][0..-7] }
                                          .flatten()
                                          .unique()
                                          .count()
                                          .val > 1

////////////////////////////////////////////////////
/* --                   AWS                    -- */
////////////////////////////////////////////////////

// AWSBatch sanity checking
if(workflow.profile == 'awsbatch'){
    if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    if (!workflow.workDir.startsWith('s3') || !params.outdir.startsWith('s3')) exit 1, "Specify S3 URLs for workDir and outdir parameters on AWSBatch!"
}

// Check workDir/outdir paths to be S3 buckets if running on AWSBatch
// related: https://github.com/nextflow-io/nextflow/issues/813
if( workflow.profile == 'awsbatch') {
    if(!workflow.workDir.startsWith('s3:') || !params.outdir.startsWith('s3:')) exit 1, "Workdir or Outdir not on S3 - specify S3 Buckets for each to run on AWSBatch!"
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                       HEADER LOG INFO                               -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

// Header log info
log.info nfcoreHeader()
def summary = [:]
summary['Pipeline Name']              = 'nf-core/atacseq'
summary['Pipeline Version']           = workflow.manifest.version
summary['Run Name']                   = custom_runName ?: workflow.runName
summary['Genome']                     = params.genome ? params.genome : 'Not supplied'
summary['Data Type']                  = params.singleEnd ? 'Single-End' : 'Paired-End'
summary['Design File']                = params.design
if(params.bwa_index_dir)  summary['BWA Index Directory'] = params.bwa_index_dir ? params.bwa_index_dir : 'Not supplied'
if(params.bwa_index_dir)  summary['BWA Index Base'] = params.bwa_index_base ? params.bwa_index_base : 'Not supplied'
summary['Fasta Ref']                  = params.fasta
summary['GTF File']                   = params.gtf
summary['Gene BED File']              = params.gene_bed ? params.gene_bed : 'Not supplied'
summary['TSS BED File']               = params.tss_bed ? params.tss_bed : 'Not supplied'
if(params.blacklist) summary['Blacklist BED'] = params.blacklist
summary['Mitochondrial Contig']       = params.mito_name ? params.mito_name : 'Not supplied'
summary['MACS Genome Size']           = params.macs_gsize ? params.macs_gsize : 'Not supplied'
if(params.macs_gsize)  summary['MACS Narrow Peaks'] = params.narrowPeak ? 'Yes' : 'No'
if( params.skipTrimming ){
    summary['Trimming Step']          = 'Skipped'
} else {
    summary['Trim R1']                = "$params.clip_r1 bp"
    summary['Trim R2']                = "$params.clip_r2 bp"
    summary["Trim 3' R1"]             = "$params.three_prime_clip_r1 bp"
    summary["Trim 3' R2"]             = "$params.three_prime_clip_r2 bp"
}
summary['Fragment Size']              = "$params.fragment_size bp"
summary['BWA MEM']                    = params.bwa_aln ? 'No' : 'Yes'
summary['Keep Mitochondrial']         = params.keepMito ? 'Yes' : 'No'
summary['Keep Duplicates']            = params.keepDups ? 'Yes' : 'No'
summary['Keep Multi-mapped']          = params.keepMultiMap ? 'Yes' : 'No'
summary['Merge Replicates']           = params.skipMergeReplicates ? 'No' : 'Yes'
summary['Save Reference']             = params.saveReference ? 'Yes' : 'No'
summary['Save Trimmed']               = params.saveTrimmed ? 'Yes' : 'No'
summary['Save Intermeds']             = params.saveAlignedIntermediates ? 'Yes' : 'No'
summary['Max Memory']                 = params.max_memory
summary['Max CPUs']                   = params.max_cpus
summary['Max Time']                   = params.max_time
summary['Output Dir']                 = params.outdir
summary['Working Dir']                = workflow.workDir
summary['Container Engine']           = workflow.containerEngine
if(workflow.containerEngine) summary['Container'] = workflow.container
summary['Current Home']               = "$HOME"
summary['Current User']               = "$USER"
summary['Current Path']               = "$PWD"
summary['Working Dir']                = workflow.workDir
summary['Output Dir']                 = params.outdir
summary['Script Dir']                 = workflow.projectDir
summary['Config Profile']             = workflow.profile
if(params.config_profile_description) summary['Config Description'] = params.config_profile_description
if(params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if(params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if(workflow.profile == 'awsbatch'){
   summary['AWS Region']              = params.awsregion
   summary['AWS Queue']               = params.awsqueue
}
if(params.email) summary['E-mail Address'] = params.email
log.info summary.collect { k,v -> "${k.padRight(21)}: $v" }.join("\n")
log.info "\033[2m----------------------------------------------------\033[0m"

// Show a big warning message if we're not running MACS
if (!params.macs_gsize){
    def warnstring = params.genome ? "supported for '${params.genome}'" : 'supplied'
    log.warn "=================================================================\n" +
             "  WARNING! MACS genome size parameter not $warnstring.\n" +
             "  Peak calling, annotation and differential analysis will be skipped.\n" +
             "  Please specify value for '--macs_gsize' to run these steps.\n" +
             "======================================================================="
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                     PREPARE ANNOTATION FILES                        -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

/*
 * PREPROCESSING - Build BWA index
 */
if(!params.bwa_index_dir){
    process makeBWAindex {
        tag "$fasta"
        label 'process_big'
        publishDir path: { params.saveReference ? "${params.outdir}/reference_genome" : params.outdir },
                   saveAs: { params.saveReference ? it : null }, mode: 'copy'

        input:
        file fasta from fasta_bwa_index

        output:
        file "BWAIndex" into bwa_index_read1,
                             bwa_index_read2,
                             bwa_index_sai_to_sam

        script:
        """
        bwa index -a bwtsw $fasta
        mkdir BWAIndex && mv ${fasta}* BWAIndex
        """
    }
}

/*
 * PREPROCESSING - Generate gene BED file
 */
if(!params.gene_bed){
    process makeGeneBED {
        tag "$gtf"
        publishDir path: { params.saveReference ? "${params.outdir}/reference_genome" : params.outdir },
                   saveAs: { params.saveReference ? it : null }, mode: 'copy'

        input:
        file gtf from gtf_gene_bed

        output:
        file "*.bed" into gene_bed

        script: // This script is bundled with the pipeline, in nf-core/atacseq/bin/
        """
        gtf2bed $gtf > ${gtf.baseName}.bed
        """
    }
}

/*
 * PREPROCESSING - Generate TSS BED file
 */
if(!params.tss_bed){
    process makeTSSBED {
        tag "$bed"
        publishDir path: { params.saveReference ? "${params.outdir}/reference_genome" : params.outdir },
                   saveAs: { params.saveReference ? it : null }, mode: 'copy'

        input:
        file bed from gene_bed

        output:
        file "*.bed" into tss_bed

        script:
        """
        cat $bed | awk -v FS='\t' -v OFS='\t' '{ if(\$6=="+") \$3=\$2+1; else \$2=\$3-1; print \$1, \$2, \$3, \$4, \$5, \$6;}' > ${bed.baseName}.tss.bed
        """
    }
}

/*
 * PREPROCESSING - Prepare genome intervals for filtering
 */
process makeGenomeFilter {
    tag "$fasta"
    publishDir path: { params.saveReference ? "${params.outdir}/reference_genome" : params.outdir },
             saveAs: { params.saveReference ? it : null }, mode: 'copy'

    input:
    file fasta from fasta_genome_filter

    output:
    file "*.fai" into genome_fai                    // FAI INDEX FOR REFERENCE GENOME
    file "*.txt" into genome_autosomes              // TEXT FILE CONTAINING LISTING OF AUTOSOMAL CHROMOSOMES FOR ATAQV
    file "*.bed" into genome_filter_regions         // BED FILE WITHOUT BLACKLIST REGIONS & MITOCHONDRIAL CONTIG FOR FILTERING
    file "*.sizes" into genome_sizes_mlib_bigwig,   // CHROMOSOME SIZES FILE FOR BEDTOOLS
                        genome_sizes_mrep_bigwig

    script:
    blacklist_filter = params.blacklist ? "sortBed -i ${params.blacklist} -g ${fasta}.sizes | complementBed -i stdin -g ${fasta}.sizes" : "awk '{print \$1, '0' , \$2}' OFS='\t' ${fasta}.sizes"
    name_filter = params.mito_name ? "| awk '\$1 !~ /${params.mito_name}/ {print \$0}'": ""
    mito_filter = params.keepMito ? "" : name_filter
    """
    samtools faidx $fasta
    get_autosomes.py ${fasta}.fai ${fasta}.autosomes.txt
    cut -f 1,2 ${fasta}.fai > ${fasta}.sizes
    $blacklist_filter $mito_filter > ${fasta}.includable.bed
    """
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                        FASTQ QC                                     -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

/*
 * STEP 1 - FastQC
 */
process fastqc {
    tag "$name"
    label 'process_medium'
    publishDir "${params.outdir}/fastqc", mode: 'copy',
        saveAs: {filename -> filename.endsWith(".zip") ? "zips/$filename" : "$filename"}

    input:
    set val(name), file(reads) from raw_reads_fastqc

    output:
    file "*.{zip,html}" into fastqc_reports_mqc

    script:
    // Added soft-links to original fastqs for consistent naming in MultiQC
    if (params.singleEnd) {
        """
        [ ! -f  ${name}.fastq.gz ] && ln -s $reads ${name}.fastq.gz
        fastqc -q ${name}.fastq.gz
        """
    } else {
        """
        [ ! -f  ${name}_1.fastq.gz ] && ln -s ${reads[0]} ${name}_1.fastq.gz
        [ ! -f  ${name}_2.fastq.gz ] && ln -s ${reads[1]} ${name}_2.fastq.gz
        fastqc -q ${name}_1.fastq.gz
        fastqc -q ${name}_2.fastq.gz
        """
    }
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                        ADAPTER TRIMMING                             -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

/*
 * STEP 2 - Trim Galore!
 */
if(params.skipTrimming){
    raw_reads_trimgalore.into { trimmed_reads_aln_1;
                                trimmed_reads_aln_2;
                                trimmed_reads_sai_to_sam }
    trimgalore_results_mqc = []
    trimgalore_fastqc_reports_mqc = []
} else {
    process trim_galore {
        tag "$name"
        label 'process_long'
        publishDir "${params.outdir}/trim_galore", mode: 'copy',
            saveAs: {filename ->
                if (filename.endsWith(".html")) "fastqc/$filename"
                else if (filename.endsWith(".zip")) "fastqc/zip/$filename"
                else if (filename.endsWith("trimming_report.txt")) "logs/$filename"
                else params.saveTrimmed ? filename : null
            }

        input:
        set val(name), file(reads) from raw_reads_trimgalore

        output:
        set val(name), file("*.fq.gz") into trimmed_reads_aln_1,
                                            trimmed_reads_aln_2,
                                            trimmed_reads_sai_to_sam
        file "*.txt" into trimgalore_results_mqc
        file "*.{zip,html}" into trimgalore_fastqc_reports_mqc

        script:
        // Added soft-links to original fastqs for consistent naming in MultiQC
        c_r1 = params.clip_r1 > 0 ? "--clip_r1 ${params.clip_r1}" : ''
        c_r2 = params.clip_r2 > 0 ? "--clip_r2 ${params.clip_r2}" : ''
        tpc_r1 = params.three_prime_clip_r1 > 0 ? "--three_prime_clip_r1 ${params.three_prime_clip_r1}" : ''
        tpc_r2 = params.three_prime_clip_r2 > 0 ? "--three_prime_clip_r2 ${params.three_prime_clip_r2}" : ''
        if (params.singleEnd) {
            """
            [ ! -f  ${name}.fastq.gz ] && ln -s $reads ${name}.fastq.gz
            trim_galore --fastqc --gzip $c_r1 $tpc_r1 ${name}.fastq.gz
            """
        } else {
            """
            [ ! -f  ${name}_1.fastq.gz ] && ln -s ${reads[0]} ${name}_1.fastq.gz
            [ ! -f  ${name}_2.fastq.gz ] && ln -s ${reads[1]} ${name}_2.fastq.gz
            trim_galore --paired --fastqc --gzip $c_r1 $c_r2 $tpc_r1 $tpc_r2 ${name}_1.fastq.gz ${name}_2.fastq.gz
            """
        }
    }
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                        ALIGN                                        -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

/*
 * STEP 3.1 - Align read 1 with bwa
 */
if(!params.bwa_aln){
    process bwa_mem {
        tag "$name"
        label 'process_medium'

        input:
        set val(name), file(reads) from trimmed_reads_aln_1
        file index from bwa_index_read1.first()

        output:
        set val(name), file("*.bam") into bwa_bam

        script:
        rg="\'@RG\\tID:${name}\\tSM:${name.toString().subSequence(0, name.length() - 3)}\\tPL:ILLUMINA\\tLB:${name}\\tPU:1\'"
        """
        bwa mem -t $task.cpus -M -R $rg ${index}/${params.bwa_index_base} $reads | samtools view -@ $task.cpus -b -h -F 256 -O BAM -o ${name}.bam -
        """
    }
} else {
    /*
     * STEP 3.1 - Align reads with bwa aln
     */
    process bwa_aln_read1 {
        tag "$name"
        label 'process_medium'

        input:
        set val(name), file(reads) from trimmed_reads_aln_1
        file index from bwa_index_read1.first()

        output:
        set val(name), file("*.sai") into sai_read1

        script:
        sainame = params.singleEnd ? "${name}.sai" : "${name}_1.sai"
        """
        bwa aln -t $task.cpus ${index}/${params.bwa_index_base} ${reads[0]} > $sainame
        """
    }

    if(params.singleEnd){
        sai_to_sam = trimmed_reads_sai_to_sam.join(sai_read1, by: [0])
    } else {
        process bwa_aln_read2 {
            tag "$name"
            label 'process_medium'

            input:
            set val(name), file(reads) from trimmed_reads_aln_2
            file index from bwa_index_read2.first()

            output:
            set val(name), file("*.sai") into sai_read2

            script:
            """
            bwa aln -t $task.cpus ${index}/${params.bwa_index_base} ${reads[1]} > ${name}_2.sai
            """
        }
        sai_to_sam = trimmed_reads_sai_to_sam.join(sai_read1, by: [0])
                                             .join(sai_read2, by: [0])
                                             .map { it -> [it[0], it[1], [ it[2], it[3] ] ] }
    }

    process bwa_sai_to_bam {
        tag "$name"
        label 'process_extra_long'

        input:
        set val(name), file(fastqs), file(sais) from sai_to_sam
        file index from bwa_index_sai_to_sam.first()

        output:
        set val(name), file("*.bam") into bwa_bam

        script:
        command = params.singleEnd ? "bwa samse" : "bwa sampe"
        rg="\'@RG\\tID:${name}\\tSM:${name.toString().subSequence(0, name.length() - 3)}\\tPL:ILLUMINA\\tLB:${name}\\tPU:1\'"
        """
        $command -r $rg ${index}/${params.bwa_index_base} $sais $fastqs > ${name}.sam
        samtools view -@ $task.cpus -b -h -O BAM -o ${name}.bam $sam
        """
    }
}

/*
 * STEP 3.2 - Convert .bam to coordinate sorted .bam
 */
process sort_bam {
    tag "$name"
    label 'process_medium'
    if (params.saveAlignedIntermediates) {
        publishDir path: "${params.outdir}/bwa/library", mode: 'copy',
            saveAs: { filename ->
                    if (filename.endsWith(".flagstat")) "flagstat/$filename"
                    else if (filename.endsWith(".idxstats")) "idxstats/$filename"
                    else filename }
    }

    input:
    set val(name), file(bam) from bwa_bam

    output:
    set val(name), file("*.sorted.{bam,bam.bai}") into sort_bam_mlib
    file "*.{flagstat,idxstats}" into sort_bam_flagstat_mqc

    script:
    """
    samtools sort -@ $task.cpus -o ${name}.sorted.bam -T $name $bam
    samtools index ${name}.sorted.bam
    samtools flagstat ${name}.sorted.bam > ${name}.sorted.bam.flagstat
    samtools idxstats ${name}.sorted.bam > ${name}.sorted.bam.idxstats
    """
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                    MERGE LIBRARY BAM                                -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

/*
 * STEP 4.1 Merge BAM files for all libraries from same replicate
 */
sort_bam_mlib.map { it -> [ it[0].toString().subSequence(0, it[0].length() - 3), it[1] ] }
             .groupTuple(by: [0])
             .map { it ->  [ it[0], it[1].flatten() ] }
             .set { sort_bam_mlib }

process merge_library {
    tag "$name"
    label 'process_medium'
    publishDir "${params.outdir}/bwa/mergeLibrary", mode: 'copy',
        saveAs: { filename ->
            if (filename.endsWith(".flagstat")) "flagstat/$filename"
            else if (filename.endsWith(".idxstats")) "idxstats/$filename"
            else if (filename.endsWith(".metrics.txt")) "picard_metrics/$filename"
            else params.saveAlignedIntermediates ? filename : null
        }

    input:
    set val(name), file(bams) from sort_bam_mlib

    output:
    set val(name), file("*${prefix}.sorted.{bam,bam.bai}") into mlib_bam_filter,
                                                                mlib_bam_ataqv
    file "*.{flagstat,idxstats}" into mlib_bam_stats_mqc
    file "*.txt" into mlib_metrics_mqc

    script:
    prefix="${name}.mLb.mkD"
    bam_files = bams.findAll { it.toString().endsWith('.bam') }.sort()
    if( !task.memory ){
        log.info "[Picard MarkDuplicates] Available memory not known - defaulting to 3GB. Specify process memory requirements to change this."
        avail_mem = 3
    } else {
        avail_mem = task.memory.toGiga()
    }
    if (bam_files.size() > 1) {
        """
        picard -Xmx${avail_mem}g MergeSamFiles \\
               ${'INPUT='+bam_files.join(' INPUT=')} \\
               OUTPUT=${name}.sorted.bam \\
               SORT_ORDER=coordinate \\
               VALIDATION_STRINGENCY=LENIENT \\
               TMP_DIR=tmp
        samtools index ${name}.sorted.bam

        picard -Xmx${avail_mem}g MarkDuplicates \\
               INPUT=${name}.sorted.bam \\
               OUTPUT=${prefix}.sorted.bam \\
               ASSUME_SORTED=true \\
               REMOVE_DUPLICATES=false \\
               METRICS_FILE=${prefix}.MarkDuplicates.metrics.txt \\
               VALIDATION_STRINGENCY=LENIENT \\
               TMP_DIR=tmp

        samtools index ${prefix}.sorted.bam
        samtools idxstats ${prefix}.sorted.bam > ${prefix}.sorted.bam.idxstats
        samtools flagstat ${prefix}.sorted.bam > ${prefix}.sorted.bam.flagstat
        """
    } else {
      """
      picard -Xmx${avail_mem}g MarkDuplicates \\
             ${'INPUT='+bam_files.join(' INPUT=')} \\
             OUTPUT=${prefix}.sorted.bam \\
             ASSUME_SORTED=true \\
             REMOVE_DUPLICATES=false \\
             METRICS_FILE=${prefix}.MarkDuplicates.metrics.txt \\
             VALIDATION_STRINGENCY=LENIENT \\
             TMP_DIR=tmp

      samtools index ${prefix}.sorted.bam
      samtools idxstats ${prefix}.sorted.bam > ${prefix}.sorted.bam.idxstats
      samtools flagstat ${prefix}.sorted.bam > ${prefix}.sorted.bam.flagstat
      """
    }
}

/*
 * STEP 4.2 Filter BAM file at merged library-level
 */
process merge_library_filter {
    tag "$name"

    label 'process_medium'
    publishDir path: "${params.outdir}/bwa/mergeLibrary", mode: 'copy',
        saveAs: { filename ->
            if (params.singleEnd || params.saveAlignedIntermediates) {
                if (filename.endsWith(".flagstat")) "flagstat/$filename"
                else filename }
            }

    input:
    set val(name), file(bam) from mlib_bam_filter
    file bed from genome_filter_regions.collect()
    file bamtools_filter_se_config from bamtools_filter_se_config_ch.collect()
    file bamtools_filter_pe_config from bamtools_filter_pe_config_ch.collect()

    output:
    set val(name), file("*.{bam,bam.bai}") into mlib_filter_bam
    file "*.flagstat" into mlib_filter_flagstat

    script:
    prefix = params.singleEnd ? "${name}.mLb.clN" : "${name}.mLb.flT"
    filter_params = params.singleEnd ? "-F 0x004 -F 0x0100" : "-f 0x001 -F 0x004 -F 0x0008 -F 0x0100"
    dup_params = params.keepDups ? "" : "-F 0x0400"
    multimap_params = params.keepMultiMap ? "" : "-q 1"
    bamtools_filter_config = params.singleEnd ? bamtools_filter_se_config : bamtools_filter_pe_config
    name_sort_bam = params.singleEnd ? "" : "samtools sort -n -@ $task.cpus -o ${prefix}.bam -T $prefix ${prefix}.sorted.bam"
    """
    samtools view \\
             $filter_params \\
             $dup_params \\
             $multimap_params \\
             -L $bed \\
             -b ${bam[0]} \\
             | bamtools filter \\
                        -out ${prefix}.sorted.bam \\
                        -script $bamtools_filter_config

    samtools index ${prefix}.sorted.bam
    samtools flagstat ${prefix}.sorted.bam > ${prefix}.sorted.bam.flagstat
    $name_sort_bam
    """
}

/*
 * STEP 4.3 Remove orphan reads from paired-end BAM file
 */
if(params.singleEnd){
    mlib_filter_bam.into { mlib_rm_orphan_bam_bigwig;
                           mlib_rm_orphan_bam_macs;
                           mlib_rm_orphan_bam_mrep;
                           mlib_name_bam_mlib_counts;
                           mlib_name_bam_mrep_counts }
    mlib_filter_flagstat.into { mlib_rm_orphan_flagstat_bigwig;
                                mlib_rm_orphan_flagstat_macs;
                                mlib_rm_orphan_flagstat_mqc }
} else {
    process merge_library_rm_orphan {
        tag "$name"
        label 'process_medium'
        publishDir path: "${params.outdir}/bwa/mergeLibrary", mode: 'copy',
            saveAs: { filename ->
                if (filename.endsWith(".flagstat")) "flagstat/$filename"
                else if (filename.endsWith(".sorted.bam")) filename
                else if (filename.endsWith(".sorted.bam.bai")) filename
                else null
            }

        input:
        set val(name), file(bam) from mlib_filter_bam

        output:
        set val(name), file("*.sorted.{bam,bam.bai}") into mlib_rm_orphan_bam_metrics,
                                                           mlib_rm_orphan_bam_bigwig,
                                                           mlib_rm_orphan_bam_macs,
                                                           mlib_rm_orphan_bam_mrep
        set val(name), file("${prefix}.bam") into mlib_name_bam_mlib_counts,
                                                  mlib_name_bam_mrep_counts
        set val(name), "*.flagstat" into mlib_rm_orphan_flagstat_bigwig,
                                          mlib_rm_orphan_flagstat_macs,
                                          mlib_rm_orphan_flagstat_mqc

        script: // This script is bundled with the pipeline, in nf-core/atacseq/bin/
        prefix="${name}.mLb.clN"
        """
        bampe_rm_orphan.py ${bam[0]} ${prefix}.bam --only_fr_pairs
        samtools sort -@ $task.cpus -o ${prefix}.sorted.bam -T $prefix ${prefix}.bam
        samtools index ${prefix}.sorted.bam
        samtools flagstat ${prefix}.sorted.bam > ${prefix}.sorted.bam.flagstat
        """
    }
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                 MERGE LIBRARY BAM POST-ANALYSIS                     -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

/*
 * STEP 4.4.1 Picard CollectMultipleMetrics at after merging libraries
 */
process merge_library_collectmetrics {
    tag "$name"
    label 'process_medium'
    publishDir path: "${params.outdir}/bwa/mergeLibrary", mode: 'copy',
        saveAs: { filename ->
            if (filename.endsWith("_metrics")) "picard_metrics/$filename"
            else if (filename.endsWith(".pdf")) "picard_metrics/pdf/$filename"
            else null
        }

    input:
    set val(name), file(bam) from mlib_rm_orphan_bam_metrics
    file fasta from fasta_mlib_metrics.collect()

    output:
    file "*_metrics" into mlib_collectmetrics_mqc
    file "*.pdf" into mlib_collectmetrics_pdf

    script:
    prefix="${name}.mLb.clN"
    if( !task.memory ){
        log.info "[Picard CollectMultipleMetrics] Available memory not known - defaulting to 3GB. Specify process memory requirements to change this."
        avail_mem = 3
    } else {
        avail_mem = task.memory.toGiga()
    }
    """
    picard -Xmx${avail_mem}g CollectMultipleMetrics \\
           INPUT=${bam[0]} \\
           OUTPUT=${prefix}.CollectMultipleMetrics \\
           REFERENCE_SEQUENCE=$fasta \\
           VALIDATION_STRINGENCY=LENIENT \\
           TMP_DIR=tmp
    """
}

/*
 * STEP 4.4.2 Read depth normalised bigWig
 */
process merge_library_bigwig {
    tag "$name"
    label 'process_long'
    publishDir "${params.outdir}/bwa/mergeLibrary/bigwig", mode: 'copy',
        saveAs: {filename ->
                    if (filename.endsWith(".txt")) "scale/$filename"
                    else if (filename.endsWith(".bigWig")) "$filename"
                    else null
                }

    input:
    set val(name), file(bam), file(flagstat) from mlib_rm_orphan_bam_bigwig.join(mlib_rm_orphan_flagstat_bigwig, by: [0])
    file sizes from genome_sizes_mlib_bigwig.collect()

    output:
    file "*.bigWig" into mlib_bigwig_igv
    file "*.txt" into mlib_bigwig_scale

    script:
    prefix="${name}.mLb.clN"
    pe_fragment = params.singleEnd ? "" : "-pc"
    extend = (params.singleEnd && params.fragment_size > 0) ? "-fs ${params.fragment_size}" : ''
    """
    SCALE_FACTOR=\$(grep 'mapped (' $flagstat | awk '{print 1000000/\$1}')
    echo \$SCALE_FACTOR > ${prefix}.scale_factor.txt
    genomeCoverageBed -ibam ${bam[0]} -bg -scale \$SCALE_FACTOR $pe_fragment $extend | sort -k1,1 -k2,2n >  ${prefix}.bedGraph
    bedGraphToBigWig ${prefix}.bedGraph $sizes ${prefix}.bigWig
    """
}

/*
 * STEP 4.5.1 Call peaks with MACS2 and calculate FRiP score
 */
process merge_library_macs {
    tag "$name"
    label 'process_long'
    publishDir "${params.outdir}/bwa/mergeLibrary/macs", mode: 'copy',
        saveAs: {filename ->
                    if (filename.endsWith(".tsv")) "qc/$filename"
                    else filename
                }

    input:
    set val(name), file(bam), file(flagstat) from mlib_rm_orphan_bam_macs.join(mlib_rm_orphan_flagstat_macs, by: [0])
    file mlib_peak_count_header from mlib_peak_count_header_ch.collect()
    file mlib_frip_score_header from mlib_frip_score_header_ch.collect()

    output:
    set val(name), file("*.{bed,xls,gappedPeak}") into mlib_macs_output
    set val(name), file("*$peakext") into mlib_macs_peaks_homer,
                                          mlib_macs_peaks_qc,
                                          mlib_macs_peaks_consensus,
                                          mlib_macs_peaks_ataqv,
                                          mlib_macs_peaks_igv
    file "*_mqc.tsv" into mlib_macs_peaks_mqc

    when: params.macs_gsize

    script:
    prefix="${name}.mLb.clN"
    peakext = params.narrowPeak ? ".narrowPeak" : ".broadPeak"
    broad = params.narrowPeak ? '' : "--broad"
    format = params.singleEnd ? "BAM" : "BAMPE"
    """
    macs2 callpeak \\
         -t ${bam[0]} \\
         $broad \\
         -f $format \\
         -g ${params.macs_gsize} \\
         -n ${prefix} \\
         --keep-dup all \\
         --nomodel

    cat ${prefix}_peaks${peakext} | wc -l | awk -v OFS='\t' '{ print "${name}", \$1 }' | cat $mlib_peak_count_header - > ${prefix}_peaks.count_mqc.tsv

    READS_IN_PEAKS=\$(intersectBed -a ${bam[0]} -b ${prefix}_peaks${peakext} -bed -c -f 0.20 | awk -F '\t' '{sum += \$NF} END {print sum}')
    grep 'mapped (' $flagstat | awk -v a="\$READS_IN_PEAKS" -v OFS='\t' '{print "${name}", a/\$1}' | cat $mlib_frip_score_header - > ${prefix}_peaks.FRiP_mqc.tsv
    """
}

/*
 * STEP 4.5.2 Annotate peaks with HOMER
 */
process merge_library_macs_annotate {
    tag "$name"
    publishDir "${params.outdir}/bwa/mergeLibrary/macs", mode: 'copy'

    input:
    set val(name), file(peak) from mlib_macs_peaks_homer
    file fasta from fasta_mlib_macs_annotate.collect()
    file gtf from gtf_mlib_macs_annotate.collect()

    output:
    file "*.txt" into mlib_macs_annotate

    when: params.macs_gsize

    script:
    prefix="${name}.mLb.clN"
    """
    annotatePeaks.pl $peak \\
                     $fasta \\
                     -gid \\
                     -gtf $gtf \\
                     > ${prefix}_peaks.annotatePeaks.txt
    """
}

/*
 * STEP 4.5.3 Aggregated QC plots for peaks, FRiP and peak-to-gene annotation
 */
process merge_library_macs_qc {
   publishDir "${params.outdir}/bwa/mergeLibrary/macs/qc", mode: 'copy'

   input:
   file peaks from mlib_macs_peaks_qc.collect{ it[1] }
   file annos from mlib_macs_annotate.collect()
   file mlib_peak_annotation_header from mlib_peak_annotation_header_ch.collect()

   output:
   file "*.{txt,pdf}" into mlib_macs_qc
   file "*.tsv" into mlib_macs_qc_mqc

   when: params.macs_gsize

   script:  // This script is bundled with the pipeline, in nf-core/atacseq/bin/
   suffix='mLb.clN'
   peakext = params.narrowPeak ? ".narrowPeak" : ".broadPeak"
   """
   plot_macs_qc.r -i ${peaks.join(',')} \\
                  -s ${peaks.join(',').replaceAll(".${suffix}_peaks${peakext}","")} \\
                  -o ./ \\
                  -p macs_peak.${suffix}

   plot_homer_annotatepeaks.r -i ${annos.join(',')} \\
                              -s ${annos.join(',').replaceAll(".${suffix}_peaks.annotatePeaks.txt","")} \\
                              -o ./ \\
                              -p macs_annotatePeaks.${suffix}

   cat $mlib_peak_annotation_header macs_annotatePeaks.${suffix}.summary.txt > macs_annotatePeaks.${suffix}.summary_mqc.tsv
   """
}

/*
 * STEP 4.5.4 Consensus peaks across samples, create boolean filtering file, .saf file for featureCounts and UpSetR plot for intersection
 */
process merge_library_macs_consensus {
    publishDir "${params.outdir}/bwa/mergeLibrary/macs/consensus", mode: 'copy'

    input:
    file peaks from mlib_macs_peaks_consensus.collect{ it[1] }

    output:
    file "*.bed" into mlib_macs_consensus_bed,
                      mlib_macs_consensus_bed_igv
    file "*.boolean.txt" into mlib_macs_consensus_bool
    file "*.saf" into mlib_macs_consensus_saf
    file "*.intersect.{txt,plot.pdf}" into mlib_macs_consensus_intersect

    when: params.macs_gsize && (multiple_samples || replicates_exist)

    script: // scripts are bundled with the pipeline, in nf-core/atacseq/bin/
    suffix='mLb.clN'
    prefix="consensus_peaks.${suffix}"
    peakext = params.narrowPeak ? ".narrowPeak" : ".broadPeak"
    mergecols = params.narrowPeak ? (2..10).join(',') : (2..9).join(',')
    collapsecols = params.narrowPeak ? (["collapse"]*9).join(',') : (["collapse"]*8).join(',')
    expandparam = params.narrowPeak ? "--is_narrow_peak" : ""
    """
    sort -k1,1 -k2,2n ${peaks.collect{it.toString()}.sort().join(' ')} \\
         | mergeBed -c $mergecols -o $collapsecols > ${prefix}.txt

    macs2_merged_expand.py ${prefix}.txt \\
                           ${peaks.collect{it.toString()}.sort().join(',').replaceAll("_peaks${peakext}","")} \\
                           ${prefix}.boolean.txt \\
                           --min_samples 1 \\
                           $expandparam

    awk -v FS='\t' -v OFS='\t' 'FNR > 1 { print \$1, \$2, \$3, \$4, "0", "+" }' ${prefix}.boolean.txt > ${prefix}.bed

    echo -e "GeneID\tChr\tStart\tEnd\tStrand" > ${prefix}.saf
    awk -v FS='\t' -v OFS='\t' 'FNR > 1 { print \$4, \$1, \$2, \$3,  "+" }' ${prefix}.boolean.txt >> ${prefix}.saf

    sed -i 's/.${suffix}//g' ${prefix}.boolean.intersect.txt
    plot_peak_intersect.r -i ${prefix}.boolean.intersect.txt -o ${prefix}.boolean.intersect.plot.pdf
    """
}

/*
 * STEP 4.5.5 Annotate consensus peaks with HOMER, and add annotation to boolean output file
 */
process merge_library_macs_consensus_annotate {
    publishDir "${params.outdir}/bwa/mergeLibrary/macs/consensus", mode: 'copy'

    input:
    file bed from mlib_macs_consensus_bed
    file bool from mlib_macs_consensus_bool
    file fasta from fasta_mlib_macs_consensus_annotate
    file gtf from gtf_mlib_macs_consensus_annotate

    output:
    file "*.annotatePeaks.txt" into mlib_macs_consensus_annotate

    when: params.macs_gsize && (multiple_samples || replicates_exist)

    script:
    prefix="consensus_peaks.mLb.clN"
    """
    annotatePeaks.pl $bed \\
                     $fasta \\
                     -gid \\
                     -gtf $gtf \\
                     > ${prefix}.annotatePeaks.txt

    cut -f2- ${prefix}.annotatePeaks.txt | awk 'NR==1; NR > 1 {print \$0 | "sort -k1,1 -k2,2n"}' | cut -f6- > tmp.txt
    paste $bool tmp.txt > ${prefix}.boolean.annotatePeaks.txt
    """
}

/*
 * STEP 4.5.6 Count reads in consensus peaks with featureCounts and perform differential analysis with DESeq2
 */
process merge_library_macs_consensus_deseq {
    label 'process_medium'
    publishDir "${params.outdir}/bwa/mergeLibrary/macs/consensus/deseq2", mode: 'copy'

    input:
    file bams from mlib_name_bam_mlib_counts.collect{ it[1] }
    file saf from mlib_macs_consensus_saf.collect()
    file mlib_deseq2_pca_header from mlib_deseq2_pca_header_ch.collect()
    file mlib_deseq2_clustering_header from mlib_deseq2_clustering_header_ch.collect()

    output:
    file "*featureCounts.txt" into mlib_macs_consensus_counts
    file "*featureCounts.txt.summary" into mlib_macs_consensus_counts_mqc
    file "*.{RData,results.txt,pdf,log}" into mlib_macs_consensus_deseq_results
    file "sizeFactors" into mlib_macs_consensus_deseq_factors
    file "*vs*/*.{pdf,txt}" into mlib_macs_consensus_deseq_comp_results
    file "*vs*/*.bed" into mlib_macs_consensus_deseq_comp_bed_igv
    file "*.tsv" into mlib_macs_consensus_deseq_mqc

    when: params.macs_gsize && multiple_samples && replicates_exist

    script:
    prefix="consensus_peaks.mLb.clN"
    bam_files = bams.findAll { it.toString().endsWith('.bam') }.sort()
    bam_ext = params.singleEnd ? ".mLb.clN.sorted.bam" : ".mLb.clN.bam"
    pe_params = params.singleEnd ? '' : "-p --donotsort"
    """
    featureCounts -F SAF \\
                  -O \\
                  --fracOverlap 0.2 \\
                  -T $task.cpus \\
                  $pe_params \\
                  -a $saf \\
                  -o ${prefix}.featureCounts.txt \\
                  ${bam_files.join(' ')}

    featurecounts_deseq2.r -i ${prefix}.featureCounts.txt -b '$bam_ext' -o ./ -p $prefix -s .mLb

    cat $mlib_deseq2_pca_header ${prefix}.pca.vals.txt > ${prefix}.pca.vals_mqc.tsv
    cat $mlib_deseq2_clustering_header ${prefix}.sample.dists.txt > ${prefix}.sample.dists_mqc.tsv
    """
}

/*
 * STEP 4.7.1 Run ataqv on BAM file and corresponding peaks
 */
process merge_library_ataqv {
   tag "$name"
   label 'process_medium'
   publishDir "${params.outdir}/bwa/mergeLibrary/ataqv", mode: 'copy'

   input:
   set val(name), file(bam), file(peak) from mlib_bam_ataqv.join(mlib_macs_peaks_ataqv, by: [0])
   file tss_bed from tss_bed.collect()
   file autosomes from genome_autosomes.collect()

   output:
   file "*.json" into mlib_ataqv

   script:
   peak_param = params.macs_gsize ? "--peak-file ${peak}" : ""
   mito_param = params.mito_name ? "--mitochondrial-reference-name ${params.mito_name}" : ""
   """
   ataqv --threads $task.cpus \\
         $peak_param  \\
         --tss-file $tss_bed \\
         --metrics-file  ${name}.ataqv.json \\
         --name $name \\
         --ignore-read-groups \\
         --autosomal-reference-file $autosomes \\
         $mito_param \\
         NA \\
         ${bam[0]}
   """
}

/*
 * STEP 4.7.2 run ataqv mkarv on all JSON files to render web app
 */
process merge_library_ataqv_mkarv {
   label 'process_medium'
   publishDir "${params.outdir}/bwa/mergeLibrary/ataqv/html", mode: 'copy'

   input:
   file json from mlib_ataqv.collect()

   output:
   file "html/*" into mlib_ataqv_mkarv

   script:
   """
   mkarv --concurrency $task.cpus \\
         --force \\
         ./ \\
         ${json.join(' ')}
   """
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                    MERGE REPLICATE BAM                              -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

/*
 * STEP 5.1 Merge library BAM files across all replicates
 */
mlib_rm_orphan_bam_mrep.map { it -> [ it[0].toString().subSequence(0, it[0].length() - 3), it[1] ] }
                       .groupTuple(by: [0])
                       .map { it ->  [ it[0], it[1].flatten() ] }
                       .set { mlib_rm_orphan_bam_mrep }

process merge_replicate {
    tag "$name"
    label 'process_medium'
    publishDir "${params.outdir}/bwa/mergeReplicate", mode: 'copy',
        saveAs: {filename ->
                    if (filename.endsWith(".flagstat")) "flagstat/$filename"
                    else if (filename.endsWith(".metrics.txt")) "picard_metrics/$filename"
                    else filename
                }

    input:
    set val(name), file(bams) from mlib_rm_orphan_bam_mrep

    output:
    set val(name), file("*${prefix}.sorted.{bam,bam.bai}") into mrep_bam_bigwig,
                                                                mrep_bam_macs
    set val(name), file("*.flagstat") into mrep_flagstat_bigwig,
                                           mrep_flagstat_macs,
                                           mrep_flagstat_mqc
    file "*.txt" into mrep_metrics_mqc

    when: !skipMergeReplicates && replicates_exist

    script:
    prefix="${name}.mRp.clN"
    bam_files = bams.findAll { it.toString().endsWith('.bam') }.sort()
    if( !task.memory ){
        log.info "[Picard MarkDuplicates] Available memory not known - defaulting to 3GB. Specify process memory requirements to change this."
        avail_mem = 3
    } else {
        avail_mem = task.memory.toGiga()
    }
    if (bam_files.size() > 1) {
        """
        picard -Xmx${avail_mem}g MergeSamFiles \\
               ${'INPUT='+bam_files.join(' INPUT=')} \\
               OUTPUT=${name}.sorted.bam \\
               SORT_ORDER=coordinate \\
               VALIDATION_STRINGENCY=LENIENT \\
               TMP_DIR=tmp
        samtools index ${name}.sorted.bam

        picard -Xmx${avail_mem}g MarkDuplicates \\
               INPUT=${name}.sorted.bam \\
               OUTPUT=${prefix}.sorted.bam \\
               ASSUME_SORTED=true \\
               REMOVE_DUPLICATES=true \\
               METRICS_FILE=${prefix}.MarkDuplicates.metrics.txt \\
               VALIDATION_STRINGENCY=LENIENT \\
               TMP_DIR=tmp

        samtools index ${prefix}.sorted.bam
        samtools flagstat ${prefix}.sorted.bam > ${prefix}.sorted.bam.flagstat
        """
    } else {
      """
      ln -s ${bams[0]} ${prefix}.sorted.bam
      ln -s ${bams[1]} ${prefix}.sorted.bam.bai
      touch ${prefix}.MarkDuplicates.metrics.txt
      samtools flagstat ${prefix}.sorted.bam > ${prefix}.sorted.bam.flagstat
      """
    }
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --              MERGE REPLICATE BAM POST-ANALYSIS                      -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

/*
 * STEP 5.2.1 Read depth normalised bigWig
 */
process merge_replicate_bigwig {
    tag "$name"
    label 'process_long'
    publishDir "${params.outdir}/bwa/mergeReplicate/bigwig", mode: 'copy',
        saveAs: {filename ->
                    if (filename.endsWith(".txt")) "scale/$filename"
                    else if (filename.endsWith(".bigWig")) "$filename"
                    else null
                }

    input:
    set val(name), file(bam), file(flagstat) from mrep_bam_bigwig.join(mrep_flagstat_bigwig, by: [0])
    file sizes from genome_sizes_mrep_bigwig.collect()

    output:
    file "*.bigWig" into mrep_bigwig_igv
    file "*.txt" into mrep_bigwig_scale

    when: !skipMergeReplicates && replicates_exist

    script:
    prefix="${name}.mRp.clN"
    pe_fragment = params.singleEnd ? "" : "-pc"
    extend = (params.singleEnd && params.fragment_size > 0) ? "-fs ${params.fragment_size}" : ''
    """
    SCALE_FACTOR=\$(grep 'mapped (' $flagstat | awk '{print 1000000/\$1}')
    echo \$SCALE_FACTOR > ${prefix}.scale_factor.txt
    genomeCoverageBed -ibam ${bam[0]} -bg -scale \$SCALE_FACTOR $pe_fragment $extend | sort -k1,1 -k2,2n >  ${prefix}.bedGraph
    bedGraphToBigWig ${prefix}.bedGraph $sizes ${prefix}.bigWig
    """
}

/*
 * STEP 5.2.2 Call peaks with MACS2 and calculate FRiP score
 */
process merge_replicate_macs {
    tag "$name"
    label 'process_long'
    publishDir "${params.outdir}/bwa/mergeReplicate/macs", mode: 'copy',
        saveAs: {filename ->
                    if (filename.endsWith(".tsv")) "qc/$filename"
                    else filename
                }

    input:
    set val(name), file(bam), file(flagstat) from mrep_bam_macs.join(mrep_flagstat_macs, by: [0])
    file mrep_peak_count_header from mrep_peak_count_header_ch.collect()
    file mrep_frip_score_header from mrep_frip_score_header_ch.collect()

    output:
    file "*.{bed,xls,gappedPeak}" into mrep_macs_output
    set val(name), file("*$peakext") into mrep_macs_peaks_homer,
                                          mrep_macs_peaks_qc,
                                          mrep_macs_peaks_consensus,
                                          mrep_macs_peaks_igv
    file "*_mqc.tsv" into mrep_macs_peak_mqc

    when: !skipMergeReplicates && replicates_exist && params.macs_gsize

    script:
    prefix="${name}.mRp.clN"
    peakext = params.narrowPeak ? ".narrowPeak" : ".broadPeak"
    broad = params.narrowPeak ? '' : "--broad"
    format = params.singleEnd ? "BAM" : "BAMPE"
    """
    macs2 callpeak \\
         -t ${bam[0]} \\
         $broad \\
         -f $format \\
         -g ${params.macs_gsize} \\
         -n ${prefix} \\
         --keep-dup all \\
         --nomodel

    cat ${prefix}_peaks${peakext} | wc -l | awk -v OFS='\t' '{ print "${name}", \$1 }' | cat $mrep_peak_count_header - > ${prefix}_peaks.count_mqc.tsv

    READS_IN_PEAKS=\$(intersectBed -a ${bam[0]} -b ${prefix}_peaks${peakext} -bed -c -f 0.20 | awk -F '\t' '{sum += \$NF} END {print sum}')
    grep 'mapped (' $flagstat | awk -v a="\$READS_IN_PEAKS" -v OFS='\t' '{print "${name}", a/\$1}' | cat $mrep_frip_score_header - > ${prefix}_peaks.FRiP_mqc.tsv
    """
}

/*
 * STEP 5.2.3 Annotate peaks with HOMER
 */
process merge_replicate_macs_annotate {
    tag "$name"
    publishDir "${params.outdir}/bwa/mergeReplicate/macs", mode: 'copy'

    input:
    set val(name), file(peak) from mrep_macs_peaks_homer
    file fasta from fasta_mrep_macs_annotate.collect()
    file gtf from gtf_mrep_macs_annotate.collect()

    output:
    file "*.txt" into mrep_macs_annotate

    when: !skipMergeReplicates && replicates_exist && params.macs_gsize

    script:
    prefix="${name}.mRp.clN"
    """
    annotatePeaks.pl $peak \\
                     $fasta \\
                     -gid \\
                     -gtf $gtf \\
                     > ${prefix}_peaks.annotatePeaks.txt
    """
}

/*
 * STEP 5.2.4 Aggregated QC plots for peaks, FRiP and peak-to-gene annotation
 */
process merge_replicate_macs_qc {
   publishDir "${params.outdir}/bwa/mergeReplicate/macs/qc", mode: 'copy'

   input:
   file peaks from mrep_macs_peaks_qc.collect{ it[1] }
   file annos from mrep_macs_annotate.collect()
   file mrep_peak_annotation_header from mrep_peak_annotation_header_ch.collect()

   output:
   file "*.{txt,pdf}" into mrep_macs_qc
   file "*.tsv" into mrep_macs_qc_mqc

   when: !skipMergeReplicates && replicates_exist && params.macs_gsize

   script:  // This script is bundled with the pipeline, in nf-core/atacseq/bin/
   suffix='mRp.clN'
   peakext = params.narrowPeak ? ".narrowPeak" : ".broadPeak"
   """
   plot_macs_qc.r -i ${peaks.join(',')} \\
                  -s ${peaks.join(',').replaceAll(".${suffix}_peaks${peakext}","")} \\
                  -o ./ \\
                  -p macs_peak.${suffix}

   plot_homer_annotatepeaks.r -i ${annos.join(',')} \\
                              -s ${annos.join(',').replaceAll(".${suffix}_peaks.annotatePeaks.txt","")} \\
                              -o ./ \\
                              -p macs_annotatePeaks.${suffix}

   cat $mrep_peak_annotation_header macs_annotatePeaks.${suffix}.summary.txt > macs_annotatePeaks.${suffix}.summary_mqc.tsv
   """
}

/*
 * STEP 5.2.5 Consensus peaks across samples, create boolean filtering file, .saf file for featureCounts and UpSetR plot for intersection
 */
process merge_replicate_macs_consensus {
    publishDir "${params.outdir}/bwa/mergeReplicate/macs/consensus", mode: 'copy'

    input:
    file peaks from mrep_macs_peaks_consensus.collect{ it[1] }

    output:
    file "*.bed" into mrep_macs_consensus_bed,
                      mrep_macs_consensus_bed_igv
    file "*.boolean.txt" into mrep_macs_consensus_bool
    file "*.saf" into mrep_macs_consensus_saf
    file "*.intersect.{txt,plot.pdf}" into mrep_macs_consensus_intersect

    when: !skipMergeReplicates && replicates_exist && params.macs_gsize && multiple_samples

    script: // scripts are bundled with the pipeline, in nf-core/atacseq/bin/
    suffix='mRp.clN'
    prefix="consensus_peaks.${suffix}"
    peakext = params.narrowPeak ? ".narrowPeak" : ".broadPeak"
    mergecols = params.narrowPeak ? (2..10).join(',') : (2..9).join(',')
    collapsecols = params.narrowPeak ? (["collapse"]*9).join(',') : (["collapse"]*8).join(',')
    expandparam = params.narrowPeak ? "--is_narrow_peak" : ""
    """
    sort -k1,1 -k2,2n ${peaks.collect{it.toString()}.sort().join(' ')} \\
         | mergeBed -c $mergecols -o $collapsecols > ${prefix}.txt

    macs2_merged_expand.py ${prefix}.txt \\
                           ${peaks.collect{it.toString()}.sort().join(',').replaceAll("_peaks${peakext}","")} \\
                           ${prefix}.boolean.txt \\
                           --min_samples 1 \\
                           $expandparam

    awk -v FS='\t' -v OFS='\t' 'FNR > 1 { print \$1, \$2, \$3, \$4, "0", "+" }' ${prefix}.boolean.txt > ${prefix}.bed

    echo -e "GeneID\tChr\tStart\tEnd\tStrand" > ${prefix}.saf
    awk -v FS='\t' -v OFS='\t' 'FNR > 1 { print \$4, \$1, \$2, \$3,  "+" }' ${prefix}.boolean.txt >> ${prefix}.saf

    sed -i 's/.${suffix}//g' ${prefix}.boolean.intersect.txt
    plot_peak_intersect.r -i ${prefix}.boolean.intersect.txt -o ${prefix}.boolean.intersect.plot.pdf
    """
}

/*
 * STEP 5.2.6 Annotate consensus peaks with HOMER, and add annotation to boolean output file
 */
process merge_replicate_macs_consensus_annotate {
    publishDir "${params.outdir}/bwa/mergeReplicate/macs/consensus", mode: 'copy'

    input:
    file bed from mrep_macs_consensus_bed
    file bool from mrep_macs_consensus_bool
    file fasta from fasta_mrep_macs_consensus_annotate
    file gtf from gtf_mrep_macs_consensus_annotate

    output:
    file "*.annotatePeaks.txt" into mrep_macs_consensus_annotate

    when: !skipMergeReplicates && replicates_exist && params.macs_gsize && multiple_samples

    script:
    prefix="consensus_peaks.mRp.clN"
    """
    annotatePeaks.pl $bed \\
                     $fasta \\
                     -gid \\
                     -gtf $gtf \\
                     > ${prefix}.annotatePeaks.txt

    cut -f2- ${prefix}.annotatePeaks.txt | awk 'NR==1; NR > 1 {print \$0 | "sort -k1,1 -k2,2n"}' | cut -f6- > tmp.txt
    paste $bool tmp.txt > ${prefix}.boolean.annotatePeaks.txt
    """
}

/*
 * STEP 5.2.7 Count reads in consensus peaks with featureCounts and perform differential analysis with DESeq2
 */
process merge_replicate_macs_consensus_deseq {
    label 'process_medium'
    publishDir "${params.outdir}/bwa/mergeReplicate/macs/consensus/deseq2", mode: 'copy'

    input:
    file bams from mlib_name_bam_mrep_counts.collect{ it[1] }
    file saf from mrep_macs_consensus_saf.collect()
    file mrep_deseq2_pca_header from mrep_deseq2_pca_header_ch.collect()
    file mrep_deseq2_clustering_header from mrep_deseq2_clustering_header_ch.collect()

    output:
    file "*featureCounts.txt" into mrep_macs_consensus_counts
    file "*featureCounts.txt.summary" into mrep_macs_consensus_counts_mqc
    file "*.{RData,results.txt,pdf,log}" into mrep_macs_consensus_deseq_results
    file "sizeFactors" into mrep_macs_consensus_deseq_factors
    file "*vs*/*.{pdf,txt}" into mrep_macs_consensus_deseq_comp_results
    file "*vs*/*.bed" into mrep_macs_consensus_deseq_comp_bed_igv
    file "*.tsv" into mrep_macs_consensus_deseq_mqc

    when: !skipMergeReplicates && replicates_exist && params.macs_gsize && multiple_samples

    script:
    prefix="consensus_peaks.mRp.clN"
    bam_files = bams.findAll { it.toString().endsWith('.bam') }.sort()
    bam_ext = params.singleEnd ? ".mRp.clN.sorted.bam" : ".mRp.clN.bam"
    pe_params = params.singleEnd ? '' : "-p --donotsort"
    """
    featureCounts -F SAF \\
                  -O \\
                  --fracOverlap 0.2 \\
                  -T $task.cpus \\
                  $pe_params \\
                  -a $saf \\
                  -o ${prefix}.featureCounts.txt \\
                  ${bam_files.join(' ')}

    featurecounts_deseq2.r -i ${prefix}.featureCounts.txt -b '$bam_ext' -o ./ -p $prefix -s .mRp

    cat $mrep_deseq2_pca_header ${prefix}.pca.vals.txt > ${prefix}.pca.vals_mqc.tsv
    cat $mrep_deseq2_clustering_header ${prefix}.sample.dists.txt > ${prefix}.sample.dists_mqc.tsv
    """
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                          MULTIQC                                    -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

def create_workflow_summary(summary) {

    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'nf-core-atacseq-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/atacseq Workflow Summary'
    section_href: 'https://github.com/nf-core/atacseq'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}

/*
 * Parse software version numbers
 */
process get_software_versions {

    output:
    file "software_versions_mqc.yaml" into software_versions_yaml

    script:
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    fastqc --version > v_fastqc.txt
    trim_galore --version > v_trim_galore.txt
    echo \$(bwa 2>&1) > v_bwa.txt
    samtools --version > v_samtools.txt
    bedtools --version > v_bedtools.txt
    echo \$(bamtools --version 2>&1) > v_bamtools.txt
    picard MarkDuplicates --version &> v_picard.txt  || true
    echo \$(R --version 2>&1) > v_R.txt
    python -c "import pysam; print(pysam.__version__)" > v_pysam.txt
    echo \$(macs2 --version 2>&1) > v_macs2.txt
    touch v_homer.txt
    echo \$(ataqv --version 2>&1) > v_ataqv.txt
    echo \$(featureCounts -v 2>&1) > v_featurecounts.txt
    multiqc --version > v_multiqc.txt
    scrape_software_versions.py > software_versions_mqc.yaml
    """
}

/*
 * STEP 6 - MultiQC
 */
process multiqc {
    publishDir "${params.outdir}/multiqc", mode: 'copy'

    input:
    file multiqc_config from multiqc_config_ch.collect()
    file ('fastqc/*') from fastqc_reports_mqc.collect()
    file ('trimgalore/*') from trimgalore_results_mqc.collect()
    file ('trimgalore/fastqc/*') from trimgalore_fastqc_reports_mqc.collect()

    file ('alignment/library/*') from sort_bam_flagstat_mqc.collect()

    file ('alignment/mergeLibrary/*') from mlib_bam_stats_mqc.collect()
    file ('alignment/mergeLibrary/*') from mlib_rm_orphan_flagstat_mqc.collect{it[1]}
    file ('alignment/mergeLibrary/picard_metrics/*') from mlib_metrics_mqc.collect()
    file ('alignment/mergeLibrary/picard_metrics/*') from mlib_collectmetrics_mqc.collect()
    file ('macs/mergeLibrary/*') from mlib_macs_peaks_mqc.collect().ifEmpty([])
    file ('macs/mergeLibrary/*') from mlib_macs_qc_mqc.collect().ifEmpty([])
    file ('macs/mergeLibrary/consensus/*') from mlib_macs_consensus_counts_mqc.collect().ifEmpty([])
    file ('macs/mergeLibrary/consensus/*') from mlib_macs_consensus_deseq_mqc.collect().ifEmpty([])

    file ('alignment/mergeReplicate/*') from mrep_flagstat_mqc.collect{it[1]}.ifEmpty([])
    file ('alignment/mergeReplicate/*') from mrep_metrics_mqc.collect().ifEmpty([])
    file ('macs/mergeReplicate/*') from mrep_macs_peak_mqc.collect().ifEmpty([])
    file ('macs/mergeReplicate/*') from mrep_macs_qc_mqc.collect().ifEmpty([])
    file ('macs/mergeReplicate/consensus/*') from mrep_macs_consensus_counts_mqc.collect().ifEmpty([])
    file ('macs/mergeReplicate/consensus/*') from mrep_macs_consensus_deseq_mqc.collect().ifEmpty([])

    file ('software_versions/*') from software_versions_yaml.collect()
    file ('workflow_summary/*') from create_workflow_summary(summary)

    output:
    file "*multiqc_report.html" into multiqc_report
    file "*_data"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    """
    multiqc . -f $rtitle $rfilename --config $multiqc_config \\
        -m custom_content -m fastqc -m cutadapt -m samtools -m picard -m featureCounts
    """
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                             IGV                                     -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

/*
 * STEP 7 - Create IGV session file
 */
process igv {
    publishDir "${params.outdir}/igv", mode: 'copy'

    input:
    file ('bwa/mergeLibrary/bigwig/*') from mlib_bigwig_igv.collect()
    file ('bwa/mergeLibrary/macs/*') from mlib_macs_peaks_igv.collect{it[1]}.ifEmpty([])
    file ('bwa/mergeLibrary/macs/consensus/*') from mlib_macs_consensus_bed_igv.collect().ifEmpty([])
    file ('bwa/mergeLibrary/macs/consensus/deseq2/*') from mlib_macs_consensus_deseq_comp_bed_igv.collect().ifEmpty([])

    file ('bwa/mergeReplicate/bigwig/*') from mrep_bigwig_igv.collect().ifEmpty([])
    file ('bwa/mergeReplicate/macs/*') from mrep_macs_peaks_igv.collect{it[1]}.ifEmpty([])
    file ('bwa/mergeReplicate/macs/consensus/*') from mrep_macs_consensus_bed_igv.collect().ifEmpty([])
    file ('bwa/mergeReplicate/macs/consensus/deseq2/*') from mrep_macs_consensus_deseq_comp_bed_igv.collect().ifEmpty([])

    output:
    file "*.xml" into igv_session

    script: // scripts are bundled with the pipeline, in nf-core/atacseq/bin/
    """
    igv_get_files.sh ./ mLb > igv_files.txt
    igv_get_files.sh ./ mRp >> igv_files.txt
    igv_files_to_session.py igv_session.xml igv_files.txt ${params.fasta}
    """
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                       REPORTS/DOCUMENTATION                         -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

/*
 * STEP 8 - Output description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/Documentation", mode: 'copy'

    input:
    file output_docs from output_docs_ch

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.r $output_docs results_description.html
    """
}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/atacseq] Successful: $workflow.runName"
    if(!workflow.success){
      subject = "[nf-core/atacseq] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if(workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if(workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if(workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: params.email, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir" ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (params.email) {
        try {
          if( params.plaintext_email ){ throw GroovyException('Send plaintext e-mail, not HTML') }
          // Try to send HTML e-mail using sendmail
          [ 'sendmail', '-t' ].execute() << sendmail_html
          log.info "[nf-core/atacseq] Sent summary e-mail to $params.email (sendmail)"
        } catch (all) {
          // Catch failures and try with plaintext
          [ 'mail', '-s', subject, params.email ].execute() << email_txt
          log.info "[nf-core/atacseq] Sent summary e-mail to $params.email (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File( "${params.outdir}/Documentation/" )
    if( !output_d.exists() ) {
      output_d.mkdirs()
    }
    def output_hf = new File( output_d, "pipeline_report.html" )
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File( output_d, "pipeline_report.txt" )
    output_tf.withWriter { w -> w << email_txt }

    log.info "[nf-core/atacseq] Pipeline Complete"

}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                       NF-CORE HEADER                                -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

def nfcoreHeader(){
    // Log colors ANSI codes
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";

    return """    ${c_dim}----------------------------------------------------${c_reset}
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/atacseq v${workflow.manifest.version}${c_reset}
    ${c_dim}----------------------------------------------------${c_reset}
    """.stripIndent()
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                        END OF PIPELINE                              -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
