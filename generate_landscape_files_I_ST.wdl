version 1.0
task generate_landscape_files {

  input {
    String sample
    String data_dir
    String bucket_path_landscape_files
    Float scaling_factor
    Int tile_size
    Float image_scale
    Int jitter
    String celldega_docker_image
  }

  command <<<
    #!/bin/bash
    set -euo pipefail
    IFS=$'\n\t'

    SAMPLE="~{sample}"
    USER_DATA_DIR="~{data_dir}"
    USER_OUTPUT_DIR="~{bucket_path_landscape_files}"

    DATA_ROOT="${PWD}"
    OUTDIR="${DATA_ROOT}/landscape_files_temp"
    IN_DIR="${DATA_ROOT}/${SAMPLE}"

    mkdir -p "${IN_DIR}" "${OUTDIR}"

    echo "Checking data_dir source: ${USER_DATA_DIR}"

    if [[ "${USER_DATA_DIR}" == s3://* ]]; then
      echo "Detected AWS S3 path, using aws s3 sync..."

      aws s3 cp "${USER_DATA_DIR%/}/results/${SAMPLE}/${SAMPLE}.ome.tiff" "${IN_DIR}/"
      aws s3 sync "${USER_DATA_DIR%/}/intermediate_results/02_matrix/${SAMPLE}" "${IN_DIR}/"
      aws s3 cp "${USER_DATA_DIR%/}/intermediate_results/stats/sample_prep_stats_sample.csv" "${IN_DIR}/"
      aws s3 cp "${USER_DATA_DIR%/}/results/${SAMPLE}/${SAMPLE}_Expanded_5um_cell_contour_coords.csv" "${IN_DIR}/"

    elif [[ "${USER_DATA_DIR}" == gs://* ]]; then
      echo "Detected Google Cloud Storage path, using gcloud storage rsync..."

      gcloud storage cp "${USER_DATA_DIR%/}/results/${SAMPLE}/${SAMPLE}.ome.tiff" "${IN_DIR}/"
      gcloud storage rsync -r "${USER_DATA_DIR%/}/intermediate_results/02_matrix/${SAMPLE}" "${IN_DIR}/"
      gcloud storage cp "${USER_DATA_DIR%/}/intermediate_results/stats/sample_prep_stats_sample.csv" "${IN_DIR}/"
      gcloud storage cp "${USER_DATA_DIR%/}/results/${SAMPLE}/${SAMPLE}_Expanded_5um_cell_contour_coords.csv" "${IN_DIR}/"

    else
      echo "ERROR: data_dir must start with s3:// or gs://"
      exit 1
    fi

    if [[ -z "$(find "${IN_DIR}" -type f -print -quit)" ]]; then
      echo "ERROR: No files found under ${USER_DATA_DIR}/${SAMPLE}." >&2
      exit 2
    fi

    echo "Running celldega..."

    python3 /opt/IST_Landscape_Pre-process.py \
        --data_dir "${DATA_ROOT}" \
        --sample "~{sample}" \
        --path_landscape_files "${OUTDIR}" \
        --scaling_factor ~{scaling_factor} \
        --tile_size ~{tile_size} \
        --image_scale ~{image_scale} \
        --jitter ~{jitter}

    echo "Syncing outputs back to bucket..."

    if [[ "${USER_OUTPUT_DIR}" == s3://* ]]; then
      aws s3 sync "${OUTDIR}/" "${USER_OUTPUT_DIR%/}/" --no-progress
    elif [[ "${USER_OUTPUT_DIR}" == gs://* ]]; then
      gcloud storage rsync -r "${OUTDIR}/" "${USER_OUTPUT_DIR%/}/"
    else
      echo "ERROR: bucket_path_landscape_files must start with s3:// or gs://"
      exit 1
    fi

    echo "Done."
  >>>

  runtime {
    docker: celldega_docker_image
    memory: "200 GB"
    disks: "local-disk 200 HDD"
    preemptible: 0
    continueOnReturnCode: 0
  }
}
