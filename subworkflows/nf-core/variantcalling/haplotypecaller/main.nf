include { GATK4_MERGEVCFS                             as MERGE_HAPLOTYPECALLER } from '../../../../modules/nf-core/modules/gatk4/mergevcfs/main'
include { GATK4_GENOTYPEGVCFS                         as GENOTYPEGVCFS         } from '../../../../modules/nf-core/modules/gatk4/genotypegvcfs/main'
include { GATK4_HAPLOTYPECALLER                       as HAPLOTYPECALLER       } from '../../../../modules/nf-core/modules/gatk4/haplotypecaller/main'
include { GATK_JOINT_GERMLINE_VARIANT_CALLING         as JOINT_GERMLINE        } from '../../../../subworkflows/nf-core/gatk4/joint_germline_variant_calling/main'
include { GATK_SINGLE_SAMPLE_GERMLINE_VARIANT_CALLING as SINGLE_SAMPLE         } from '../../../../subworkflows/nf-core/gatk4/single_sample_germline_variant_calling/main'

workflow RUN_HAPLOTYPECALLER {
    take:
    cram                            // channel: [mandatory] [meta, cram, crai, interval.bed]
    fasta                           // channel: [mandatory]
    fasta_fai                       // channel: [mandatory]
    dict                            // channel: [mandatory]
    dbsnp                           // channel: []
    dbsnp_tbi
    known_sites_indels
    known_sites_indels_tbi
    known_sites_snps
    known_sites_snps_tbi
    intervals_bed_combined          // channel: [optional]

    main:

    ch_versions = Channel.empty()
    filtered_vcf = Channel.empty()

    HAPLOTYPECALLER(
        cram,
        fasta,
        fasta_fai,
        dict,
        dbsnp,
        dbsnp_tbi)

    // Figure out if using intervals or no_intervals
    HAPLOTYPECALLER.out.vcf.branch{
            intervals:    it[0].num_intervals > 1
            no_intervals: it[0].num_intervals <= 1
        }.set{haplotypecaller_vcf_branch}

    HAPLOTYPECALLER.out.tbi.branch{
            intervals:    it[0].num_intervals > 1
            no_intervals: it[0].num_intervals <= 1
        }.set{haplotypecaller_tbi_branch}

    if (params.joint_germline) {
        // merge vcf and tbis
        genotype_gvcf_to_call = Channel.empty().mix(HAPLOTYPECALLER.out.vcf
                                .join(HAPLOTYPECALLER.out.tbi)
                                .join(cram).map{ meta, vcf, tbi, cram, crai, intervals ->
                                     [ meta, vcf, tbi, intervals ]
                                     })

        genotype_vcf = JOINT_GERMLINE(
             genotype_gvcf_to_call,
             fasta,
             fasta_fai,
             dict,
             dbsnp,
             dbsnp_tbi,
             known_sites_indels,
             known_sites_indels_tbi,
             known_sites_snps,
             known_sites_snps_tbi).genotype_vcf

        ch_versions = ch_versions.mix(JOINT_GERMLINE.out.versions)
    } else {
        // Only when using intervals
        MERGE_HAPLOTYPECALLER(
            haplotypecaller_vcf_branch.intervals
                .map{ meta, vcf ->

                    new_meta = [patient:meta.patient, sample:meta.sample, status:meta.status, sex:meta.sex, id:meta.sample, num_intervals:meta.num_intervals]

                    [groupKey(new_meta, new_meta.num_intervals), vcf]
                }.groupTuple(),
            dict)

        haplotypecaller_vcf = Channel.empty().mix(
            MERGE_HAPLOTYPECALLER.out.vcf,
            haplotypecaller_vcf_branch.no_intervals)

        haplotypecaller_tbi = Channel.empty().mix(
            MERGE_HAPLOTYPECALLER.out.tbi,
            haplotypecaller_tbi_branch.no_intervals)

        if(params.variant_recalibration) {
            SINGLE_SAMPLE(haplotypecaller_vcf.join(haplotypecaller_tbi),
                        fasta,
                        fasta_fai,
                        dict,
                        intervals_bed_combined,
                        known_sites_indels.concat(known_sites_snps).unique().collect(),
                        known_sites_indels_tbi.concat(known_sites_snps_tbi).unique().collect())

            filtered_vcf = SINGLE_SAMPLE.out.filtered_vcf
            ch_versions = ch_versions.mix(SINGLE_SAMPLE.out.versions)
        } else {

            filtered_vcf = MERGE_HAPLOTYPECALLER.out.vcf
        }
    }


    ch_versions = ch_versions.mix(HAPLOTYPECALLER.out.versions, MERGE_HAPLOTYPECALLER.out.versions)

    emit:
    versions = ch_versions
    filtered_vcf
}
