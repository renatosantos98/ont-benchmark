#!/usr/bin/env nextflow

/*
========================================================================================
    IMPORT MODULES
========================================================================================
*/

include { SPLIT_SNV_INDELS } from '../modules/setup/split_snv_indels.nf'
include { COLLECT_UNIQUE_MICROARRAY_VARIANT_IDS } from '../modules/setup/collect_unique_microarray_variant_ids.nf'
include { CONVERT_TO_RSIDS } from '../modules/setup/convert_to_rsids.nf'
include { QUERY_RSID_POSITIONS } from '../modules/setup/query_rsid_positions.nf'
include { UPDATE_MICROARRAY_VCF } from '../modules/setup/update_microarray_vcf.nf'
include { SORT_VCF } from '../modules/setup/sort_vcf.nf'
include { GENERATE_SDF_REFERENCE } from '../modules/setup/generate_sdf_reference.nf'

/*
========================================================================================
    INITIALISE PARAMETER CHANNELS
========================================================================================
*/

// Sample IDs
Channel
    .fromPath('./sample_ids.csv', checkIfExists: true)
    .splitCsv(header: true)
    .map { row -> tuple(row.ont_id, row.lp_id) }
    .set { sample_ids_ch }

// Input VCF files
sample_ids_ch.flatMap { ont_id, lp_id ->
    def files = []
    def missing_files = []

    // Microarray
    def microarray_file = file("${params.microarray_dir}/FinalReport_InfiniumOmni2-5-8v1-4_${lp_id}.vcf.gz")
    if (microarray_file.exists()) {
        files << tuple([id: lp_id, type: 'microarray', variant: 'snv'], microarray_file)
    } else {
        missing_files << "Microarray file for ${lp_id}"
    }

    // Illumina
    def illumina_file = file("${params.illumina_dir}/${lp_id}.vcf.gz")
    if (illumina_file.exists()) {
        files << tuple([id: lp_id, type: 'illumina', variant: 'snv_indel'], illumina_file)
    } else {
        missing_files << "Illumina SNV/INDEL file for ${lp_id}"
    }

    def illumina_sv_file = file("${params.illumina_dir}/${lp_id}.SV.vcf.gz")
    if (illumina_sv_file.exists()) {
        files << tuple([id: lp_id, type: 'illumina', variant: 'sv'], illumina_sv_file)
    } else {
        missing_files << "Illumina SV file for ${lp_id}"
    }

    // ONT
    //['snp', 'sv', 'str', 'cnv'].each { variant ->
    ['snp', 'sv', 'str'].each { variant ->
        def ont_file = file("${params.ont_dir}/${ont_id}_${params.basecall}/${ont_id}_${params.basecall}.wf_${variant}.vcf.gz")
        if (ont_file.exists()) {
            files << tuple([id: ont_id, type: 'ont', variant: variant], ont_file)
        } else {
            missing_files << "ONT ${variant.toUpperCase()} file for ${ont_id}"
        }
    }

    if (!missing_files.isEmpty()) {
        error "The following required files are missing:\n${missing_files.join('\n')}\nPlease ensure all required files exist before running the pipeline."
    }

    return files
    }.branch {
        microarray: it[0].type == 'microarray'
        illumina_snv_indel: it[0].type == 'illumina' && it[0].variant == 'snv_indel'
        illumina_sv: it[0].type == 'illumina' && it[0].variant == 'sv'
        ont_snv_indel: it[0].type == 'ont' && it[0].variant == 'snp'
        ont_sv: it[0].type == 'ont' && it[0].variant == 'sv'
        ont_str: it[0].type == 'ont' && it[0].variant == 'str'
        ont_cnv: it[0].type == 'ont' && it[0].variant == 'cnv'
    }.set { all_vcf_files }

sample_ids_map = [:]
sample_ids_ch.subscribe { ont_id, lp_id ->
    sample_ids_map[ont_id] = lp_id
    sample_ids_map[lp_id] = ont_id
}

microarray_ch = all_vcf_files.microarray
illumina_snv_indel_ch = all_vcf_files.illumina_snv_indel
illumina_sv_ch = all_vcf_files.illumina_sv
ont_snv_indel_ch = all_vcf_files.ont_snv_indel
ont_sv_ch = all_vcf_files.ont_sv
ont_str_ch = all_vcf_files.ont_str
ont_cnv_ch = all_vcf_files.ont_cnv

Channel
    .fromPath( params.reference_fasta, checkIfExists: true )
    .set { reference_fasta_ch }

Channel
    .fromPath( params.array_positions_file, checkIfExists: true )
    .set { array_positions_ch }

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    WORKFLOW: SETUP
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow SETUP {
    main:
    snv_indel_files = illumina_snv_indel_ch
        .mix(ont_snv_indel_ch)
        .combine(reference_fasta_ch)

    SPLIT_SNV_INDELS(snv_indel_files)

    SPLIT_SNV_INDELS.out.snv
        .map { meta, vcf -> tuple([id: meta.id, type: meta.type, variant: 'snv'], vcf) }
        .set { snv_ch }

    SPLIT_SNV_INDELS.out.indel
        .map { meta, vcf -> tuple([id: meta.id, type: meta.type, variant: 'indel'], vcf) }
        .set { indel_ch }

    microarray_vcfs_ch = microarray_ch.map { meta, vcf -> vcf }.collect()
    COLLECT_UNIQUE_MICROARRAY_VARIANT_IDS(microarray_vcfs_ch)

    CONVERT_TO_RSIDS(
        COLLECT_UNIQUE_MICROARRAY_VARIANT_IDS.out.unique_variant_ids,
        array_positions_ch
    )

    QUERY_RSID_POSITIONS(
        CONVERT_TO_RSIDS.out.unique_rsids,
        array_positions_ch
    )

    UPDATE_MICROARRAY_VCF(
        microarray_ch
            .combine(QUERY_RSID_POSITIONS.out.rsid_positions)
            .combine(reference_fasta_ch)
    )

    all_vcf_files_ch = illumina_sv_ch
        .mix(ont_sv_ch)
        .mix(ont_str_ch)
        .mix(ont_cnv_ch)
        .mix(snv_ch)
        .mix(indel_ch)
        .mix(UPDATE_MICROARRAY_VCF.out.pos_vcf)

    SORT_VCF(
        all_vcf_files_ch.map { meta, vcf -> tuple(meta, vcf) }
    )

    SORT_VCF.out
        .map { meta, vcf, index ->
            def ont_id = meta.type == 'ont' ? meta.id : sample_ids_map[meta.id]
            def lp_id = meta.type == 'ont' ? sample_ids_map[meta.id] : meta.id
            tuple(ont_id, lp_id, meta.type, meta.variant, vcf, index)
        }
        .branch {
            snv: it[3] == 'snv' || (it[2] == 'microarray' && it[3] == 'snv')
            indel: it[3] == 'indel'
            sv: it[3] == 'sv'
            str: it[3] == 'str'
            cnv: it[3] == 'cnv'
        }
        .set { variant_channels }

    def process_variant_channel = { channel, include_array ->
        channel
            .groupTuple(by: [0, 1])
            .map { ont_id, lp_id, types, variants, vcfs, indices ->
                def grouped = [ont: null, illumina: null, microarray: null]
                for (i in 0..<types.size()) {
                    grouped[types[i]] = tuple(vcfs[i], indices[i])
                }
                def result = [ont_id, lp_id]
                result += grouped.ont ?: [null, null]
                result += grouped.illumina ?: [null, null]
                if (include_array) {
                    result += grouped.microarray ?: [null, null]
                }
                tuple(*result)
            }
    }

    snv_samples_ch = process_variant_channel(variant_channels.snv, true)
    indel_samples_ch = process_variant_channel(variant_channels.indel, false)
    sv_samples_ch = process_variant_channel(variant_channels.sv, false)
    str_samples_ch = process_variant_channel(variant_channels.str, false)
    cnv_samples_ch = process_variant_channel(variant_channels.cnv, false)

    GENERATE_SDF_REFERENCE(
        reference_fasta_ch
    )

    reference_sdf_ch = GENERATE_SDF_REFERENCE.out.reference_sdf

    emit:
    snv_samples_ch
    indel_samples_ch
    sv_samples_ch
    str_samples_ch
    cnv_samples_ch
    reference_sdf_ch
}
