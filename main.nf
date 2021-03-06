#!/usr/bin/env nextflow
/*
========================================================================================
                         NGI-NeutronStar
========================================================================================
 NGI-NeutronStar Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/scilifelab/NGI-NeutronStar
 #### Authors
 Remi-Andre Olsen remiolsen <remi-andre.olsen@scilifelab.se> - https://github.com/remiolsen
----------------------------------------------------------------------------------------
*/


def helpMessage() {
    log.info"""
    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run -profile name scilifelab/NGI-NeutronStar --id assembly_id --fastqs fastq_path --genomesize 1000000

    Mandatory arguments:
      --id                          [Supernova parameter]
      --fastqs                      [Supernova parameter]
      --genomesize                  The estimated size of the genome(s) to be assembled. This is mainly used by Quast to compute NGxx statstics, e.g. N50 statistics bound by this value and not the assembly size.
      -profile                      Hardware config to use. docker / hpc
      --BUSCOdata                   The dataset BUSCO should use (e.g. eukaryota_odb9, protists_ensembl)

    Options:
      --sample                      [Supernova parameter]
      --lanes                       [Supernova parameter]
      --indices                     [Supernova parameter]
      --bcfrac                      [Supernova parameter]
      --project                     [Supernova parameter]
      --maxreads                    [Supernova parameter]
      --nopreflight                 [Supernova parameter]
      --minsize                     [Supernova mkdoutput parameter]
      --max_cpus                    Amount of cpu cores for the job scheduler to request. Supernova will use all of them. (default=16 for hpc config)
      --max_memory                  Amount of memory (in Gb) for the jobscheduler to request. Supernova will use all of it. (default=256 for hpc config)
      --max_time                    Amount of time for the job scheduler to request (in hours). (default=120)
      --full_output                 Keep all the files that are output from Supernova. By default only the final assembly graph is kept, as it is needed to make the output fasta files.
      -process.clusterOptions       The options to feed to the HPC job manager. For instance for SLURM --clusterOptions='-A project -C node-type'


    Other options:
      --outdir                      The output directory where the results will be saved
      --email                       Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      -name                         Name for the pipeline run. If not specified, the pipeline will automatically generate one from the uuid (i.e. nonsense).
      -params-file                  Give the arguments for this nextflow run as a structured JSON/YAML file
    """.stripIndent()
}



/*
 * SET UP CONFIGURATION VARIABLES
 */

// Pipeline version
version = '0.5dev'

log.info "     \\|/"
log.info "  ----*----   N G I - N e u t r o n S t a r (${version})"
log.info "     /|\\"
log.info ""
// Show help emssage
params.help = false
if (params.help){
    helpMessage()
    exit 0
}

// Common options for both supernova and longranger
def TenX_optional = { sample, lanes, indices, project ->
    def str = ""
    sample!=null ? str <<= "--sample=${sample} " : null
    lanes!=null ? str <<= "--lanes=${lanes} " : null
    indices!=null ? str <<= "--indices=${indices} " : null
    project!=null ? str <<= "--project=${project} " : null
    return str
}
// Now only supernova options
def supernova_optional = { maxreads, bcfrac, nopreflight ->
    def str = ""
    maxreads!=null ? str <<= "--maxreads=${maxreads} " : null
    bcfrac!=null ? str <<= "--bcfrac=${bcfrac} " : null
    nopreflight!=null ? str << "--nopreflight " : null
    return str
}


//##### Parameters
params.name = false
params.email = false
params.plaintext_email = false
params.outdir = "."
params.mqc_config = "$baseDir/misc/multiqc_config.yaml"
params.minsize = 1000
params.full_output = false
params.BUSCOfolder = "$baseDir/data"
def buscoPath = "${params.BUSCOfolder}/${params.BUSCOdata}"


// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
  custom_runName = workflow.runName
}else {
  custom_runName = "supernova_assembly_${workflow.sessionId}"
}


samples = []
if (params.samples == null) { // We don't have sample JSON/YAML file, just use cmd-line
    assert params.id != null : "Missing --id option"
    assert params.fastqs != null : "Missing --fastqs option"
    s = []
    s << params.id
    s << params.fastqs
    s << TenX_optional(params.sample, params.lanes, params.indices, params.project)
    s << supernova_optional(params.maxreads, params.bcfrac, params.nopreflight)
    samples << s
}

params.samples = []

for (sample in params.samples) {
    assert sample.id != null : "Error in input parameter file"
    assert sample.fastqs != null : "Error in input parameter file"
    s = []
    s << sample.id
    s << sample.fastqs
    s << TenX_optional(sample.sample, sample.lanes, sample.indices, sample.project)
    s << supernova_optional(sample.maxreads, sample.bcfrac, sample.nopreflight)
    samples << s
}


// Extra parameter evaluation
for (sample in params.samples) {
    assert sample.id.size() == sample.id.findAll(/[A-z0-9\\.\-]/).size() : "Illegal character(s) in sample ID: ${sample.id}."
    assert new File(sample.fastqs).exists() : "Path not found ${sample.fastqs}"
}
assert new File(buscoPath).exists() : "Path not found ${buscoPath}"

// Check that Nextflow version is up to date enough
// try / throw / catch works for NF versions < 0.25 when this was implemented
nf_required_version = '0.28.0'
try {
    if( ! nextflow.version.matches(">= $nf_required_version") ){
        throw new RuntimeException('Nextflow version too old')
    }
} catch (all) {
    log.error "====================================================\n" +
              "  Nextflow version $nf_required_version required! You are running v$workflow.nextflow.version.\n" +
              "  Pipeline execution will continue, but things may break.\n" +
              "  Please run `nextflow self-update` to update Nextflow.\n" +
              "============================================================"
}


//###### Start
def summary = [:]
summary['Run Name']     = custom_runName
summary['Output dir']   = params.outdir
summary['Working dir']  = workflow.workDir
summary['Container']    = workflow.container
if(workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Current home']   = "$HOME"
summary['Current user']   = "$USER"
summary['Current path']   = "$PWD"
summary['Script dir']     = workflow.projectDir
summary['Config Profile'] = workflow.profile
if(params.email) summary['E-mail Address'] = params.email
log.info summary.collect { k,v -> "${k.padRight(15)}: $v" }.join("\n")

for (i in samples) {
    log.info "  supernova run --id=${i[0]} --fastqs=${i[1]} ${i[2]} ${i[3]}"
}


process software_versions {

    output:
    file 'software_versions_mqc.yaml' into software_versions_yaml

    script:
    """
    echo $version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    supernova run --version > v_supernova.txt
    quast.py -v &> v_quast.txt
    multiqc --version > v_multiqc.txt
    BUSCO.py -v 2> v_busco.txt
    scrape_software_versions.py > software_versions_mqc.yaml
    """
}


supernova_input = Channel.from(samples)
if (params.full_output) {
    process supernova_full {
        tag id
        publishDir "${params.outdir}/supernova/", mode: 'copy'

        input:
        set val(id), val(fastqs), val(tenx_options), val(supernova_options) from supernova_input

        output:
        set val(id), file("${id}/*") into supernova_results, supernova_results2

        script:
        """
        supernova run \\
            --id=$id \\
            --fastqs=$fastqs \\
            $tenx_options \\
            $supernova_options
        """
    }

}else {
    process supernova {
        tag id
        publishDir "${params.outdir}/supernova/", mode: 'copy'

        input:
        set val(id), val(fastqs), val(tenx_options), val(supernova_options) from supernova_input

        output:
        set val(id), file("${id}_supernova") into supernova_results, supernova_results2

        script:
        """
        supernova run \\
            --id=$id \\
            --fastqs=$fastqs \\
            $tenx_options \\
            $supernova_options
        rsync \\
            -rav \\
            --include="_*" \\
            --include="*.tgz" \\
            --include="outs/" \\
            --include="outs/*.*" \\
            --include="assembly/" \\
            --include="stats/***" \\
            --include="logs/***" \\
            --include="a.base/" \\
            --include="a.base/" \\
            --include="a.hbx" \\
            --include="a.inv" \\
            --include="final/***" \\
            --include="gang" \\
            --include="micro"  \\
            --include="a.hbx" \\
            --include="a.inv" \\
            --include="final/***" \\
            --exclude="*" \\
                "${id}/" ${id}_supernova
        """
    }

}

process mkoutput {
    tag id
    publishDir "${params.outdir}/assemblies/", mode: 'copy'

    input:
    set val(id), file(supernova_folder) from supernova_results

    output:
    set val(id), file("${id}.fasta") into supernova_asm1, supernova_asm2
    file "${id}.phased.fasta"

    script:
    """
    supernova mkoutput \\
        --asmdir=${id}_supernova/outs/assembly \\
        --outprefix=$id \\
        --style=pseudohap \\
        --minsize=$params.minsize
    supernova mkoutput \\
        --asmdir=${id}_supernova/outs/assembly \\
        --outprefix=${id}.phased \\
        --style=megabubbles \\
        --minsize=$params.minsize
    gzip -d ${id}.fasta.gz
    gzip -d ${id}.phased.fasta.gz
    """
}

process quast {
    tag id
    publishDir "${params.outdir}/quast/${id}", mode: 'copy'

    input:
    set val(id), file(asm) from supernova_asm1

    output:
    file("quast_results/latest/*") into quast_results

    script:
    def size_parameter = params.genomesize != null ? "--est-ref-size ${params.genomesize}" : ""
    """
    quast.py $size_parameter --threads $task.cpus $asm
    """
}

if(workflow.container == [:]) { //BUSCO is installed on this system
    process busco {
        tag id
        publishDir "${params.outdir}/busco/", mode: 'copy'

        input:
        set val(id), file(asm) from supernova_asm2

        output:
        file ("run_${id}/") into busco_results

        script:
        // If statement is only for UPPMAX HPC environments, it shouldn't mess up anything else
        """
        if ! [ -z \${BUSCO_SETUP+x} ]; then source \$BUSCO_SETUP; fi
        BUSCO.py -i $asm -o $id -c $task.cpus -m genome -l $buscoPath
        """
    }
}
else { // We assume we are running the ngi-neutronstar Docker/Singularity container
    process busco_containerized {
        tag id
        publishDir "${params.outdir}/busco/", mode: 'copy'

        input:
        set val(id), file(asm) from supernova_asm2
        env BUSCO_CONFIG_FILE from "\$PWD/busco_config/config.ini"
        env AUGUSTUS_CONFIG_PATH from "\$PWD/augustus_config"

        output:
        file ("run_${id}/") into busco_results

        script:
        """
        mkdir busco_config; print_busco_config.py > busco_config/config.ini
        tar xfj $baseDir/misc/augustus_config.tar.bz2
        BUSCO.py -i $asm -o $id -c $task.cpus -m genome -l $buscoPath
        """
    }

}

process multiqc {
    publishDir "${params.outdir}/multiqc"

    input:
    file ('supernova/') from supernova_results2.toList()
    file ('busco/') from busco_results.toList()
    file ('quast/') from quast_results.toList()
    file ('software_versions/') from software_versions_yaml.toList()

    output:
    file "*multiqc_report.html"
    file "*_data"

    script:
    """
    multiqc -i $custom_runName -f -s --config $params.mqc_config .
    """
}


/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[NGI-NeutronStar] Successful: ${custom_runName ?: workflow.runName}"
    if(!workflow.success){
      subject = "[NGI-NeutronStar] FAILED: ${custom_runName ?: workflow.runName}"
    }
    def email_fields = [:]
    email_fields['version'] = version
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
    if(workflow.container) email_fields['summary']['Docker image'] = workflow.container
    email_fields['software_versions'] = [:]
    email_fields['software_versions']['Nextflow Build'] = workflow.nextflow.build
    email_fields['software_versions']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/misc/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/misc/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: params.email, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir" ]
    def sf = new File("$baseDir/misc/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (params.email) {
        try {
          if( params.plaintext_email ){ throw new RuntimeException('Send plaintext e-mail, not HTML') }
          // Try to send HTML e-mail using sendmail
          [ 'sendmail', '-t' ].execute() << sendmail_html
          log.info "[NGI-NeutronStar] Sent summary e-mail to $params.email (sendmail)"
        } catch (all) {
          // Catch failures and try with plaintext
          [ 'mail', '-s', subject, params.email ].execute() << email_txt
          log.info "[NGI-NeutronStar] Sent summary e-mail to $params.email (mail)"
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

    log.info "[NGI-NeutronStar] Pipeline Complete"

}
