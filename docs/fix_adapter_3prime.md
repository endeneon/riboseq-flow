# Chat Session Summary — Fixing the Missing 3′ Adapter in riboseq-flow

## Session Metadata

- **Date:** 2026-06-15
- **Pipeline:** `iraiosub/riboseq-flow` (local clone at `/research_jude/rgs01_jude/groups/cab/projects/automapper/common/szhang37/pulled_git_repos/riboseq-flow`)
- **Run/launch dir:** `/research/groups/tayl1grp/projects/tayl1grp_cab/common/TAYL1-870795-STRANDED/riboseq_flow_test`
- **Nextflow work dir:** `/lustre_scratch/user_scratch/szhang37/nextflow_work/riboseq_flow_test.2026-06-15.15:07:21`
- **Executor:** LSF on St. Jude HPC, Singularity containers, Nextflow 25.04.8
- **Goal of session:** Diagnose why the `riboseq_flow_test` run failed at `IDENTIFY_PSITES`, verify the correct input files were used, identify the true root cause, and apply a fix.

> **Update (2026-06-15, later same day):** The adapter fix was validated — a `-resume` run carrying `--adapter_threeprime "AGATCGGAAGAGC"` completed successfully with no `IDENTIFY_PSITES` crash. A follow-up defect was then found and fixed: `conf/stjude_master.config` had `cleanup = true`, which deletes a successful run's work files and breaks later `-resume`. It was changed to `cleanup = false`. See the new section "Follow-up — Resume Cache Destroyed by `cleanup = true`" and the `conf/stjude_master.config` entry under "Code Changes".

## Tasks Completed

1. **Checked live LSF resource allocation for process `b0/872c86`** (`RIBOSEQ:PREPROCESS_READS:CUTADAPT (SRX19188681)`, LSF job `293092674`).
   - Allocated: 24 cores, 3072 MB/core (≈72 GB total reservation), 16 h walltime, queue `standard`.
   - Live usage: max memory ≈ 529 MB, ≈0.72% memory efficiency (heavily over-allocated).
   - Outcome: User decided current resource settings are fine; **no change made**.

2. **Analyzed the pipeline `.command` error log** for the failed process.
   - Failing process: `RIBOSEQ:IDENTIFY_PSITES`, exit status 1.
   - Work dir: `/lustre_scratch/user_scratch/szhang37/nextflow_work/riboseq_flow_test.2026-06-15.15:07:21/00/0f26d7f380ad257fb94a3e538ded55`.
   - Container: `ribowaltz:1.2.0--r42hdfd78af_1`.

3. **Read the Nextflow logs** (`.nextflow.log` in the launch dir).
   - Confirmed `IDENTIFY_PSITES` (LSF jobId `293094609`) completed with `exit: 1` and raised `nextflow.exception.ProcessFailedException`.

4. **Read pipeline source** to trace the P-site parameters and logic.
   - Files: `modules/local/ribowaltz.nf`, `bin/identify_psites.R`, `conf/defaults.config`, `conf/test.config`, `conf/stjude_master.config`, and the run script.
   - Confirmed `skip_psite=false` for the stjude run while `conf/test.config` uses `skip_psite=true`.

5. **Verified FASTQ and BAM file paths and sizes** to rule out wrong-input.
   - FASTQs are correct and full-size; BAMs are tiny because of a mapping collapse (not wrong files).

6. **Inspected the STAR parameters and the reads entering STAR.**
   - STAR parameters are correct for ribo-seq; reads entering STAR were ≈97% full-length (101 nt), i.e. untrimmed.

7. **Identified the true root cause:** the 3′ sequencing adapter was never trimmed because `params.adapter_threeprime` defaulted to `null`.

8. **Explained `unmapped.fastq.gz` semantics:** it is the premap (bowtie2 vs contaminants) non-aligning output — the rRNA-depleted reads — which is the intended STAR input.

9. **Applied the fix:** added `--adapter_threeprime "AGATCGGAAGAGC"` to the run command in `bsub_riboseq_flow_test_run.sh`, with an explanatory comment block, and validated script syntax (`bash -n` → OK).

10. **Validated the fix end-to-end (later same day).** A `-resume` run carrying `--adapter_threeprime "AGATCGGAAGAGC"` completed successfully (work dir `…15:07:21`, finished 18:39); `IDENTIFY_PSITES` no longer crashed.

11. **Found and fixed a resume-cache destroyer.** A subsequent resume (intended to re-run only MULTIQC) unexpectedly re-ran CUTADAPT despite an identical task hash. Inspecting `.nextflow.log.1` and the on-disk work dirs showed the successful 18:39 run's task outputs had been deleted on completion by `cleanup = true` in `conf/stjude_master.config`. Changed `cleanup = true` → `cleanup = false`. (See follow-up section below.)

## Key Decisions & Rationale

- **Keep the fix on the command line, not in `stjude_master.config`.** The adapter is a per-library-prep constant; user preferred an explicit, visible flag in the run script over a hidden site-wide default. A documentation comment block was added directly above `nextflow run` to explain why the flag is required.
- **Do not bake `skip_psite=true` into the stjude config.** The `IDENTIFY_PSITES` crash was a downstream symptom of too few mapped reads, not a P-site bug. Real (properly trimmed) data will have ample reads, so P-site identification should run normally in production.
- **Resource settings left unchanged.** Although CUTADAPT is over-allocated (24 cores/72 GB for a job peaking at ~529 MB), the user opted to leave it as is.
- **Adapter identity confirmed empirically, not assumed.** A scan of 200,000 raw reads showed the Illumina TruSeq adapter `AGATCGGAAGAGC` in 80.7% (core `GATCGGAAGAGC` in 98.3%) and the small-RNA adapter `TGGAATTCTCGGGTGCCAAGG` in 0%, so the standard TruSeq adapter is the correct value.

## Root Cause Analysis

### Symptom chain (effect → cause)

1. `IDENTIFY_PSITES` (riboWaltz `psite()`, `extremity="auto"`) crashed:
   ```text
   Error in if (extremity == "auto" & ((best_from3_tab[, perc] > best_from5_tab[, : argument is of length zero
   In addition: Warning messages:
   1: In max(perc) : no non-missing arguments to max; returning -Inf
   2: In max(perc) : no non-missing arguments to max; returning -Inf
   ```
2. Cause: too few reads reached riboWaltz (~21k–33k), because the genome BAMs were tiny.
3. Cause: STAR uniquely mapped only ≈0.05–0.06% of reads; ≈84% were `unmapped: other`.
4. Cause: ≈97% of reads entering STAR were full-length 101 nt (untrimmed). STAR runs with `--alignEndsType EndToEnd` (no soft-clipping), so reads still carrying the 3′ adapter cannot align end-to-end.
5. **Root cause:** the 3′ adapter was never removed by cutadapt. In `modules/local/cutadapt.nf` the adapter argument is only added when `params.adapter_threeprime` is truthy, and it defaulted to `null` (and was never set by the run command or `conf/stjude_master.config`).

### Read funnel (sample SRX19188681)

| Stage                                              | Reads               |
| -------------------------------------------------- | ------------------- |
| Trimmed FASTQ into premap (bowtie2)                | 151,446,331         |
| Aligned to contaminants/rRNA (63.25%)              | 95,787,893          |
| Non-contaminant → `unmapped.fastq.gz` (STAR input) | 55,658,438          |
| STAR "Number of input reads"                       | 55,658,438          |
| STAR uniquely mapped                               | 30,912 (0.06%)      |
| STAR unmapped: other                               | 46,555,832 (83.65%) |

### Why premap "worked" but genome mapping collapsed

- Premap bowtie2 uses `--very-sensitive-local` (local alignment, soft-clipping allowed), so it can still match the rRNA portion of an adapter-bearing 101 nt read.
- STAR uses `--alignEndsType EndToEnd` (no soft-clipping), so the residual adapter blocks alignment. The same untrimmed reads therefore pass premap but fail genome mapping.

## File and Data Facts (verified)

### Input FASTQs (correct and full-size)

```text
sample,fastq
SRX19188681,/research/groups/tayl1grp/projects/tayl1grp_cab/common/TAYL1-870795-STRANDED/riboseq_flow_test/fetchngs_test_fastqs/fastq/SRX19188681_SRR23242345.fastq.gz
SRX19188682,/research/groups/tayl1grp/projects/tayl1grp_cab/common/TAYL1-870795-STRANDED/riboseq_flow_test/fetchngs_test_fastqs/fastq/SRX19188682_SRR23242344.fastq.gz
```

| Sample      | Size   | Reads into premap |
| ----------- | ------ | ----------------- |
| SRX19188681 | 4.6 GB | 151,446,331       |
| SRX19188682 | 4.5 GB | 135,502,285       |

### Output BAMs (tiny — a symptom, not wrong files)

| Stage                                             | SRX19188681 | SRX19188682 |
| ------------------------------------------------- | ----------- | ----------- |
| `premapped/*.bam` (rRNA-aligned)                  | 2011 MB     | 1748 MB     |
| `mapped/*.Aligned.sortedByCoord.out.bam` (genome) | 0.8 MB      | 0.9 MB      |
| `mapped/*.Aligned.toTranscriptome.sorted.out.bam` | 3.5 MB      | 3.5 MB      |

### Adapter scan (200,000 raw reads, SRX19188681)

| Adapter                 | Present | Identity                               |
| ----------------------- | ------- | -------------------------------------- |
| `AGATCGGAAGAGC`         | 80.7%   | Illumina TruSeq universal              |
| `GATCGGAAGAGC` (core)   | 98.3%   | TruSeq core                            |
| `TGGAATTCTCGGGTGCCAAGG` | 0%      | NEBNext / TruSeq small-RNA (ruled out) |

## Code Changes

### File: `riboseq_flow_test/bsub_riboseq_flow_test_run.sh`

Added an explanatory comment block above `nextflow run` and the `--adapter_threeprime "AGATCGGAAGAGC"` flag to the command. Final state of the relevant section:

```bash
# --adapter_threeprime: 3' sequencing adapter to clip from every read with cutadapt.
# WHY REQUIRED: riboseq-flow does NOT auto-detect adapters (unlike Trim Galore in
# nf-core/riboseq). If unset, params.adapter_threeprime defaults to null and the
# cutadapt module (modules/local/cutadapt.nf) never adds '-a', so reads keep their
# 3' adapter and stay full-length (~101 nt). STAR runs --alignEndsType EndToEnd
# (no soft-clipping), so adapter-bearing reads fail to align: ~0.05% uniquely mapped,
# ~84% 'unmapped: other', tiny BAMs, and IDENTIFY_PSITES (riboWaltz) then crashes
# from too few reads. FUNCTION: cutadapt removes this sequence and everything 3' of
# it, recovering the true 26-32 nt ribosome-protected fragments for genome mapping.
# VALUE: AGATCGGAAGAGC = Illumina TruSeq universal adapter, the kit adapter for these
# libraries (confirmed present in 80.7% of raw reads; small-RNA adapter absent). This
# is a fixed library-prep constant, so it only changes if the sequencing kit changes.
nextflow run \
	"${pipeline_dir}" \
	-w "${NF_WORK_DIR}" \
	${RESUME_FLAG} \
	-c "${CUSTOM_CONFIG}" \
	--input "${INPUT_SAMPLESHEET}" \
	--outdir "${OUTPUT_DIR}" \
	--org "GRCh38" \
	--save_index \
	--skip_umi_extract \
	--strandedness "forward" \
	--adapter_threeprime "AGATCGGAAGAGC" \
	-profile "singularity"
```

### Relevant existing code (not modified) — `modules/local/cutadapt.nf`

The conditional that silently skips adapter trimming when the parameter is null:

```groovy
if (params.adapter_threeprime) adapter_args += " -a ${params.adapter_threeprime}"
if (params.adapter_fiveprime) adapter_args += " -g ${params.adapter_fiveprime}"
if (params.adapter_threeprime && params.adapter_fiveprime && params.times_trimmed < 2) params.times_trimmed = 2
```

### Relevant existing code (not modified) — `main.nf`

STAR consumes the premap non-contaminant reads:

```groovy
MAP(
    PREMAP.out.unmapped,
    ...
)
```

### Relevant existing code (not modified) — `modules/local/premap.nf`

`--un-gz` writes reads that did NOT align to the contaminant index:

```bash
bowtie2 $args \
    -U $reads \
    -p ${task.cpus} \
    -x ${smallrna_index[0].simpleName} \
    --un-gz ${sample_id}.unmapped.fastq.gz \
    -S ${sample_id}.sam \
    2> ${sample_id}.premap.log
```

### File: `conf/stjude_master.config`

**Summary of change:** Disabled Nextflow's post-run work-directory cleanup so successful runs remain resumable. Changed `cleanup = true` to `cleanup = false`, with an explanatory comment.

```groovy
// Do NOT auto-delete the work directory on successful completion.
// cleanup = true wipes every executed task's work files when a run SUCCEEDS,
// which destroys the resume cache: a later run (e.g. to re-run only MULTIQC
// after a config tweak, or to add a step) can no longer reuse CUTADAPT/STAR/etc.
// and is forced to recompute from scratch. Interrupted/failed runs were already
// safe (cleanup is success-only), but keeping the work dir after success makes
// -resume reliable in every case. Trade-off: /lustre_scratch work dirs persist
// and must be pruned manually (e.g. `nextflow clean -before <run> -f` or rm the
// dated dir under /lustre_scratch/user_scratch/$USER/nextflow_work/).
cleanup = false
```

## Follow-up — Resume Cache Destroyed by `cleanup = true`

### Trigger

After the adapter fix, an attempt to cheaply re-run **only** MULTIQC (container bumped 1.19 → 1.34, `multiqc_config.yaml` tweaked to re-enable the General Statistics table) via `-resume` unexpectedly re-ran **CUTADAPT** and everything downstream.

### Investigation

- The live run submitted CUTADAPT as fresh LSF jobs at work-dir hashes `fd/2c3500…` and `e9/a61ef8…`.
- `.nextflow.log.1` showed the prior **successful** run (finished 18:39) had executed CUTADAPT at the **exact same hashes** — so the cache key never changed.
- On disk, those task dirs still existed but every file carried a fresh 19:37–19:43 timestamp (the current run rewriting them), proving the 18:39 outputs had been **deleted**.

### Root cause

`conf/stjude_master.config` contained `cleanup = true`. Nextflow's `cleanup` deletes the work files of every executed task **on successful completion only**:

| Run                          | Work dir    | Outcome                         | Effect of `cleanup`                                        |
| ---------------------------- | ----------- | ------------------------------- | ---------------------------------------------------------- |
| 15:07 (original, no adapter) | `…15:07:21` | **FAILED** at `IDENTIFY_PSITES` | none (success-only) → genome-prep outputs survived         |
| 18:39 (resume + adapter)     | `…15:07:21` | **SUCCESS**                     | wiped all tasks it executed (CUTADAPT + downstream)        |
| 19:35 (resume for MULTIQC)   | `…15:07:21` | running                         | found CUTADAPT cache entry but emptied dir → forced re-run |

The CUTADAPT re-run was therefore **not** a cache-key change and **not** an interrupted-resume failure — it was a *post-success* resume against outputs that `cleanup` had already deleted. Interrupted/failed runs were never affected (the failed 15:07 run's reference-build tasks survived and were reused as `cached ✔`).

### Fix

Set `cleanup = false` in `conf/stjude_master.config` (see Code Changes). This keeps work dirs after success so `-resume` is reliable in every case. **Trade-off:** `/lustre_scratch` work dirs now persist and must be pruned manually (`nextflow clean` or `rm` the dated work dir).

### Related run-script behavior (`bsub_riboseq_flow_test_run.sh`)

The submission script auto-resumes only when `.nf_run_state == "running"` **and** `.nf_workdir` exists. On **success** it writes `.nf_run_state=completed` and **deletes** `.nf_workdir`, so the next submission starts a **fresh** run. To force a post-success resume (as was done to target MULTIQC), recreate both files manually:

```bash
echo "running" > .nf_run_state
echo "/lustre_scratch/user_scratch/szhang37/nextflow_work/riboseq_flow_test.<DATE>" > .nf_workdir
```

> **Scope note:** `cleanup = false` takes effect for runs **launched after** the edit; a job already running with `cleanup = true` will still clean up on its own success.

## Follow-up — `IDENTIFY_PSITES` Crash on Digit-Leading Sample Names (2026-06-16)

### Trigger

The first **production** forward-strand run (30 samples `3433650`–`3433679`, work dir
`…riboseq_flow.2026-06-15.20:01:54`) failed at `RIBOSEQ:IDENTIFY_PSITES` (LSF job
`293159729`, exit 1). Unlike the original adapter bug, this was **not** a low-read symptom:
all 30 `*.psite.tsv.gz` files, offset tables, coverage TSVs, and the earlier diagnostic plots
(length distribution, heatmaps, P-site region, frames) were written successfully. Only the
**final** `metaprofile_psite()` plotting block crashed.

### Symptom

```text
Error in parse(text = elt) : <text>:1:8: unexpected input
1: 3433650_
           ^
Calls: metaprofile_psite ... chr_parse_exprs -> map -> lapply -> FUN -> as.list -> parse
```

### Root cause

riboWaltz's `metaprofile_psite()` (called with `plot_title = "sample.transcript"`, default
`plot_style = "split"`) routes each sample name through ggplot2's `label_parsed` faceting
path, which funnels into rlang's internal `chr_parse_exprs()` → `parse(text = name)`. That
evaluates every sample name as an R expression. Sample names that **start with a digit**
(e.g. `3433650_Ribo_WT_1`) are not valid R symbols, so the parser reads `3433650` as a numeric
literal and then aborts on the `_` at column 8.

- `chr_parse_exprs` is an **internal (unexported) function of `rlang`** (v1.0.6 in the
  `ribowaltz:1.2.0` container), reached via ggplot2 3.4.1's parsed-label labeller — confirmed by
  container namespace introspection and the `r-lib/rlang` source (`R/parse.R`).
- This is why the 2-sample test run never hit it: its SRA-style names (`SRX19188681`) are
  letter-leading and parse fine. The bug only surfaces with digit-leading sample IDs.

### Fix — `bin/identify_psites.R` (2 edits)

Prefix the sample names with `"X"` (the exact convention `make.names()` uses to sanitise
non-syntactic names) only for the `metaprofile_psite()` call, then strip the `"X"` back off when
writing the PDFs so the output filenames still match the original sample IDs.

1. Immediately before the `metaprofile_psite()` call:

   ```r
   # metaprofile_psite() routes the sample names through ggplot2's label_parsed /
   # rlang::parse_exprs(), which evaluates each name as an R expression. Sample names
   # that start with a digit (e.g. 3433650_Ribo_WT_1) are not valid R symbols and abort
   # with "unexpected input". Prefix the names with "X" (the same convention make.names()
   # uses) so they parse as valid symbols; save_metaprofile_psite_plot() strips the "X"
   # back off so the output PDF filenames still match the original sample IDs.
   metaprofile_psite.ls <- filtered_psite.ls
   names(metaprofile_psite.ls) <- paste0("X", names(filtered_psite.ls))

   metaprofile <- metaprofile_psite(metaprofile_psite.ls, annotation.dt, sample = names(metaprofile_psite.ls),
                                            utr5l = 25, cdsl = 40, utr3l = 25,
                                            plot_title = "sample.transcript")
   ```

2. In `save_metaprofile_psite_plot()`, strip the leading `X` for the filename:

   ```r
   save_metaprofile_psite_plot <- function(sample_name, plots_ls) {

     plot <- plots_ls[[sample_name]]
     # sample_name is "plot_X<sample_id>": drop the "plot_" prefix and the leading "X"
     # added before plotting (see the metaprofile_psite call) so the file matches the sample ID.
     out_name <- sub("^X", "", strsplit(sample_name, "plot_")[[1]][2])
     ggplot2::ggsave(paste0(getwd(),"/ribowaltz_qc/", out_name, ".metaprofile_psite.pdf"), plot, dpi = 400, width = 12, height = 6) # save in wide format

   }
   ```

The X-prefix is confined to the metaprofile plotting block; every other output (P-site tables,
offsets, coverage, other QC plots) keeps the original sample IDs, and the metaprofile PDFs are
named e.g. `3433650_Ribo_WT_1.metaprofile_psite.pdf`.

### Validation

Verified inside the exact run container (`ribowaltz:1.2.0--r42hdfd78af_1`, ggplot2 3.4.1,
rlang 1.0.6):

- `make.names("3433650_Ribo_WT_1")` → `X3433650_Ribo_WT_1`; `parse(text = "X3433650_Ribo_WT_1")` → OK.
- A minimal repro confirmed `facet_grid(... )` with the **default** labeller is fine, while
  `label_parsed` reproduces the exact `unexpected input` error; X-prefixed levels then plot/ggsave
  cleanly.
- `sub("^X", "", "X3433650_Ribo_WT_1")` → `3433650_Ribo_WT_1` (filenames restored).
- Whole edited script passes `parse()` (`singularity exec -B /research_jude <img> Rscript -e
  "invisible(parse('bin/identify_psites.R'))"` → `PARSE_OK`, exit 0).

### Resume impact

Editing `bin/identify_psites.R` changes only the `IDENTIFY_PSITES` task hash, so a `-resume`
re-runs **only** that step (and anything downstream); all upstream tasks (cutadapt, premap, STAR,
P-site BAMs) stay cached — provided `cleanup = false` (already set) preserved the failed run's
work dir. Because the production run **failed**, `cleanup` never deleted its work dir, so resume
works directly. (Container file checks need the `-B /research_jude` bind mount; a bare
`singularity exec` cannot see host files under that path.)

### Outcome (validated 2026-06-16)

Resubmitted as LSF job `293195634`; it auto-resumed with **all upstream tasks `Cached`** and
re-ran **only** `RIBOSEQ:IDENTIFY_PSITES` (LSF job `293195791`, exit 0, ~961 s). The crash is
gone and **24 metaprofile PDFs** were published to
`riboseq_flow_results/psites/ribowaltz_qc/` (~3 MB total, none zero-byte, **no leftover `X`
prefix** in filenames, e.g. `3433650_Ribo_WT_1.metaprofile_psite.pdf`).

### Note — only 24 of 30 samples reach P-site output (expected, data-quality)

Six samples produced no `*.psite.tsv.gz` and therefore no metaprofile PDF:
`3433670_Ribo_CAPKO_3`, `3433671_Ribo_DKO_1`, `3433673_Ribo_DKO_3`, `3433674_Ribo_DKOG1_1`,
`3433677_Ribo_DKOH31A_1`, `3433678_Ribo_DKOH31A_2`. This is **not** related to the X-prefix fix.
They were removed by riboWaltz's periodicity filter in `bin/identify_psites.R`
(`length_filter(length_filter_mode = "periodicity", periodicity_threshold = 50)`, lines ~218–244):
a sample is dropped when no read length has enough reads (>50%) in a single reading frame, i.e.
no usable 3-nt periodicity. Confirmed by the drop stage (none of the 6 has a
`length_bins_for_psite.pdf`, which is written *after* the periodicity filter but *before* the final
`exclude_samples` step) and by the fact that it is **not** a depth issue — several *kept* samples
(e.g. `3433669_Ribo_CAPKO_2` 0.42 M, `3433672_Ribo_DKO_2` 0.47 M uniquely-mapped reads) have
fewer reads than dropped ones (`3433678` 1.44 M, `3433673` 1.36 M). The sample names repeat across
two sequencing batches (`3433650–64` at 30–49 % STAR-unique vs `3433665–79` at 14–26 %); all six
dropped fall in the lower-quality second batch, and every biological condition is still represented
by its first-batch triplicate plus most of the second batch, so no condition is lost.

**MAY TRY LATER — lower the periodicity threshold to 30.** `periodicity_threshold` is a tunable
pipeline parameter (`conf/defaults.config` line 77, default `50`; passed as `options[5]` to
`identify_psites.R`). Re-running with `--periodicity_threshold 30` (CLI flag) or by setting it in
`conf/stjude_master.config` may rescue some of the six borderline samples, at the cost of
**lower-confidence P-site offsets**. On `-resume` this changes only the `IDENTIFY_PSITES` task hash,
so just that step (and downstream) re-runs. **Not done yet** — deferred until after the current run
completes and the standard-threshold (50) outputs have been reviewed.

## Outstanding Issues / Next Steps

1. **Resubmit the run** (DONE 2026-06-15): a `-resume` run with `--adapter_threeprime "AGATCGGAAGAGC"` completed successfully and `IDENTIFY_PSITES` no longer crashed. For reference, the submit command is:
   ```bash
   cd /research/groups/tayl1grp/projects/tayl1grp_cab/common/TAYL1-870795-STRANDED/riboseq_flow_test
   bsub -J "run_bsub_nextflow_riboseq_flow.$(date +%F.%T)" < bsub_riboseq_flow_test_run.sh
   ```
   The run script auto-resumes (`-resume`) via its run-state files; the CUTADAPT step's command changes, so cutadapt and everything downstream (premap, STAR, QC, IDENTIFY_PSITES) re-execute, while reference-build steps remain cached.
2. **Validate after rerun:** confirm reads entering STAR collapse to ≈26–32 nt, STAR unique mapping rate rises into a healthy range (tens of %), genome BAMs grow substantially, and `IDENTIFY_PSITES` completes.
3. **Optional hardening (not done, by user choice):** could set `adapter_threeprime` as a site default in `conf/stjude_master.config`, and/or right-size CUTADAPT resources (currently 24 cores/72 GB for a ~529 MB job).
4. **Per-new-dataset check:** confirm the adapter via FastQC "Adapter Content" / "Overrepresented sequences" when a new library kit is used; the value only changes if the kit changes.

## Context for LLM Handoff

A `riboseq-flow` (iraiosub) ribosome-profiling run on St. Jude LSF failed at the `IDENTIFY_PSITES` step (riboWaltz `psite()` error: "argument is of length zero"). Investigation showed the failure was a downstream symptom: STAR genome mapping collapsed to ≈0.05% uniquely mapped with ≈84% `unmapped: other`, producing sub-1 MB genome BAMs and leaving too few reads for P-site calling. The input FASTQs were verified correct and full-size (4.5–4.6 GB; 135–151 M reads), so input selection was not the problem. The true root cause was that the 3′ sequencing adapter was never trimmed: `riboseq-flow` does not auto-detect adapters and only passes `-a` to cutadapt when `params.adapter_threeprime` is set, but it defaulted to `null` and was never specified by the run command or the `conf/stjude_master.config`. Consequently ≈97% of reads entering STAR were full-length 101 nt; because STAR uses `--alignEndsType EndToEnd` (no soft-clipping), adapter-bearing reads could not align (premap's local bowtie2 alignment tolerated them, which is why only the genome step exposed the bug). The adapter was empirically confirmed as Illumina TruSeq `AGATCGGAAGAGC` (present in 80.7% of raw reads; small-RNA adapter absent). The fix added `--adapter_threeprime "AGATCGGAAGAGC"` to the `nextflow run` command in `riboseq_flow_test/bsub_riboseq_flow_test_run.sh`, accompanied by a comment block explaining the rationale; `bash -n` syntax validation passed. The next action is to resubmit the run (auto-resume) and verify that read lengths, STAR mapping rate, BAM sizes, and `IDENTIFY_PSITES` all recover. STAR parameters themselves are correct and were intentionally left unchanged, P-site identification was intentionally NOT disabled for production, and CUTADAPT resource over-allocation was intentionally left as is. **Follow-up (same day):** the adapter fix was validated by a successful `-resume` run, and a separate defect was fixed — `conf/stjude_master.config` had `cleanup = true`, which deletes a successful run's work files and breaks later `-resume` (a subsequent MULTIQC-only resume re-ran CUTADAPT at an identical task hash because the prior successful outputs had been deleted, not because the cache key changed); it was changed to `cleanup = false`. Note the run script deletes `.nf_workdir` on success, so post-success resumes require manually recreating `.nf_run_state=running` and `.nf_workdir`.
