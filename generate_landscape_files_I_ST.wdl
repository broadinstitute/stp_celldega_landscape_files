version 1.0

task generate_landscape_files {

  input {
    String input_data_dir
    String output_dega_files_dir
    Int tile_size
    Float image_scale
    Int jitter
    String celldega_docker_image
  }

  command <<<
    #!/bin/bash
    set -euo pipefail
    IFS=$'\n\t'

    USER_INPUT_DATA_DIR="~{input_data_dir}"
    USER_OUTPUT_DEGA_FILES_DIR="~{output_dega_files_dir}"

    SAMPLE="$(basename "${USER_INPUT_DATA_DIR%/}")"
    USER_DATA_DIR="$(dirname "${USER_INPUT_DATA_DIR%/}")"

    DATA_ROOT="${PWD}"
    OUTDIR="${DATA_ROOT}/landscape_files_temp"
    IN_DIR="${DATA_ROOT}/${SAMPLE}"

    mkdir -p "${IN_DIR}" "${OUTDIR}"

    echo "Checking input_data_dir source: ${USER_INPUT_DATA_DIR}"
    echo "Detected IST run root: ${USER_DATA_DIR}"
    echo "Detected sample: ${SAMPLE}"

    if [[ "${USER_INPUT_DATA_DIR}" == s3://* ]]; then
      echo "Detected AWS S3 path, using aws s3 sync..."

      # find ome.tiff
      OME_FILE=$(aws s3 ls "${USER_DATA_DIR%/}/results/${SAMPLE}/" | awk '{print $4}' | grep '\.ome\.tiff$' | head -n1)
      aws s3 cp "${USER_DATA_DIR%/}/results/${SAMPLE}/${OME_FILE}" "${IN_DIR}/${SAMPLE}.ome.tiff"

      aws s3 sync "${USER_DATA_DIR%/}/intermediate_results/02_matrix/${SAMPLE}" "${IN_DIR}/" --exclude "._*" --exclude ".DS_Store"
      aws s3 cp "${USER_DATA_DIR%/}/intermediate_results/stats/sample_prep_stats_sample.csv" "${IN_DIR}/"

      # find contour csv
      CSV_FILE=$(aws s3 ls "${USER_DATA_DIR%/}/results/${SAMPLE}/" | awk '{print $4}' | grep '5um_cell_contour_coords\.csv$' | head -n1)
      aws s3 cp "${USER_DATA_DIR%/}/results/${SAMPLE}/${CSV_FILE}" "${IN_DIR}/${SAMPLE}_Expanded_5um_cell_contour_coords.csv"

    elif [[ "${USER_INPUT_DATA_DIR}" == gs://* ]]; then
      echo "Detected Google Cloud Storage path, using gcloud storage rsync..."

      # find ome.tiff
      OME_FILE=$(gcloud storage ls "${USER_DATA_DIR%/}/results/${SAMPLE}/" | grep '\.ome\.tiff$' | head -n1)
      gcloud storage cp "${OME_FILE}" "${IN_DIR}/${SAMPLE}.ome.tiff"

      gcloud storage rsync -r "${USER_DATA_DIR%/}/intermediate_results/02_matrix/${SAMPLE}" "${IN_DIR}/"
      gcloud storage cp "${USER_DATA_DIR%/}/intermediate_results/stats/sample_prep_stats_sample.csv" "${IN_DIR}/"

      # find contour csv
      CSV_FILE=$(gcloud storage ls "${USER_DATA_DIR%/}/results/${SAMPLE}/" | grep '5um_cell_contour_coords\.csv$' | head -n1)
      gcloud storage cp "${CSV_FILE}" "${IN_DIR}/${SAMPLE}_Expanded_5um_cell_contour_coords.csv"

    else
      echo "ERROR: input_data_dir must start with s3:// or gs://"
      exit 1
    fi

    if [[ -z "$(find "${IN_DIR}" -type f -print -quit)" ]]; then
      echo "ERROR: No files found for sample ${SAMPLE} under ${USER_DATA_DIR}." >&2
      exit 2
    fi

    echo "Running celldega..."

    python3 /opt/IST_Landscape_Pre-process.py \
        --data_dir "${DATA_ROOT}" \
        --sample "${SAMPLE}" \
        --path_landscape_files "${OUTDIR}" \
        --tile_size ~{tile_size} \
        --image_scale ~{image_scale} \
        --jitter ~{jitter}

    echo "Syncing outputs back to bucket..."

    if [[ "${USER_OUTPUT_DEGA_FILES_DIR}" == s3://* ]]; then
      aws s3 sync "${OUTDIR}/" "${USER_OUTPUT_DEGA_FILES_DIR%/}/" --no-progress

    elif [[ "${USER_OUTPUT_DEGA_FILES_DIR}" == gs://* ]]; then
      gcloud storage rsync -r "${OUTDIR}/" "${USER_OUTPUT_DEGA_FILES_DIR%/}/"

    else
      echo "ERROR: output_dega_files_dir must start with s3:// or gs://"
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