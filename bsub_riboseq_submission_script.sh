#! /bin/bash

mkdir -p log
#BSUB -n 2
#BSUB -R "rusage[mem=16G]"

#BSUB -q "priority"
#BSUB -J "run_bsub_nextflow_atac"

#BSUB -o log/out.atac
#BSUB -e log/err.atac

pipeline_dir="/research_jude/rgs01_jude/groups/cab/projects/automapper/common/szhang37/pulled_git_repos/riboseq"
work_dir="/research_jude/rgs01_jude/groups/cab/projects/automapper/common/szhang37/projects/szhang_dev/AD_ATAC"
cd "${work_dir}" || exit

INPUT_SAMPLESHEET="${work_dir}/samplesheet_PRJNA1276585.csv"
# GENOME="GRCh38"
READ_LENGTH=150
OUTPUT_DIR="${work_dir}/results/atacseq_PRJNA1276585"

fasta_path="/research_jude/rgs01_jude/groups/cab/projects/automapper/common/szhang37/CAB_workspace/Databases/cellranger_ref/refdata-cellranger-arc-GRCh38-2024-A/fasta/genome.fa"
gtf_path="/research_jude/rgs01_jude/groups/cab/projects/automapper/common/szhang37/Databases/Genome/GRCh38/gtf/gencode.v49.annotation.gtf"
bwa_index_path="/research_jude/rgs01_jude/groups/cab/projects/automapper/common/szhang37/Databases/cellranger_ref/refdata-cellranger-arc-GRCh38-2024-A/fasta"
blacklist_path="/research_jude/rgs01_jude/groups/cab/projects/automapper/common/szhang37/Databases/Genome/Blacklist/lists/hg38-blacklist.v2.bed"

module load conda3/202402
# this env runs Nextflow 25.04.8
# source /hpcf/authorized_apps/rhel8_apps/conda3/202402/install/bin/activate \
conda activate /research_jude/rgs01_jude/groups/cab/projects/automapper/common/szhang37/standalone_conda_envs/nextflow_25_04_8 || exit 1
# this is the alternate 25.10 environment
# conda activate /research_jude/rgs01_jude/groups/cab/projects/automapper/common/szhang37/projects/yang2grp/CANCER_SPLICEOSOME/nfcore_static_conda

module load singularity/4.3.5

CUSTOM_CONFIG="${work_dir}/custom_resources.config"

nextflow run \
	"${pipeline_dir}" \
	-w "/lustre_scratch/user_scratch/${USER}/nextflow_work/AD_ATAC" \
	-c "${CUSTOM_CONFIG}" \
	--input "${INPUT_SAMPLESHEET}" \
	--outdir "${OUTPUT_DIR}" \
	--read_length "${READ_LENGTH}" \
	--fasta "${fasta_path}" \
	--gtf "${gtf_path}" \
	--bwa_index "${bwa_index_path}" \
	--blacklist "${blacklist_path}" \
	--narrow_peak true \
	--macs_fdr 0.05 \
	--macs_gsize 2900000000 \
	-profile "stjude_hpcf,singularity" \
	-resume
