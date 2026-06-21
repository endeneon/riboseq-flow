#!/usr/bin/env nextflow

// Specify DSL2
nextflow.enable.dsl=2

process MULTIQC {
    // tag "${workflow.runName}"
    label 'process_medium'

    // conda "bioconda::multiqc=1.34"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/multiqc:1.34--pyhdfd78af_0' :
        'quay.io/biocontainers/multiqc:1.34--pyhdfd78af_0' }"

    publishDir "${params.outdir}/multiqc", mode: 'copy', overwrite: true

    input:
    path(logs)
    path(multiqc_config)
    path(group_config)

    output:
    path "*multiqc_report.html", emit: report
    path "*_data", emit: data
    path "versions.yml", emit: versions

    script:

    // group_config is generated from the samplesheet `group` column and applied on top of
    // the static multiqc_config (the later --config wins on any overlapping keys).

    """
    multiqc -f --config $multiqc_config --config $group_config .

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        multiqc: \$( multiqc --version | sed -e "s/multiqc, version //g" )
    END_VERSIONS
    """
}
