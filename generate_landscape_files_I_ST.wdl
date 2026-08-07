version 1.0

task generate_landscape_files {

  input {
    String sample
    String data_dir
    String bucket_path_landscape_files
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

    CELL_BINNED_DIR="${SAMPLE}_cell_binned"
    LOCAL_CELL_BINNED_DIR="${IN_DIR}/${CELL_BINNED_DIR}"

    mkdir -p "${IN_DIR}" "${OUTDIR}" "${LOCAL_CELL_BINNED_DIR}"

    echo "Checking data_dir source: ${USER_DATA_DIR}"

    if [[ "${USER_DATA_DIR}" == s3://* ]]; then
      echo "Detected AWS S3 path, using aws s3..."

      # Find and download OME-TIFF.
      OME_FILE=$(
        aws s3 ls "${USER_DATA_DIR%/}/results/${SAMPLE}/" |
          awk '{print $4}' |
          grep '\.ome\.tiff$' |
          head -n1
      )

      if [[ -z "${OME_FILE}" ]]; then
        echo "ERROR: No OME-TIFF found under ${USER_DATA_DIR%/}/results/${SAMPLE}/" >&2
        exit 2
      fi

      aws s3 cp \
        "${USER_DATA_DIR%/}/results/${SAMPLE}/${OME_FILE}" \
        "${IN_DIR}/${SAMPLE}.ome.tiff"

      # Download the 10x matrix while preserving the directory expected by
      # IST_Landscape_Pre-process.py.
      aws s3 sync \
        "${USER_DATA_DIR%/}/results/${SAMPLE}/${CELL_BINNED_DIR}/" \
        "${LOCAL_CELL_BINNED_DIR}/" \
        --no-progress

      aws s3 cp \
        "${USER_DATA_DIR%/}/intermediate_results/stats/sample_prep_stats_sample.csv" \
        "${IN_DIR}/"

      # Find and download contour CSV.
      CSV_FILE=$(
        aws s3 ls "${USER_DATA_DIR%/}/results/${SAMPLE}/" |
          awk '{print $4}' |
          grep '5um_cell_contour_coords\.csv$' |
          head -n1
      )

      if [[ -z "${CSV_FILE}" ]]; then
        echo "ERROR: No 5um cell contour CSV found under ${USER_DATA_DIR%/}/results/${SAMPLE}/" >&2
        exit 2
      fi

      aws s3 cp \
        "${USER_DATA_DIR%/}/results/${SAMPLE}/${CSV_FILE}" \
        "${IN_DIR}/${SAMPLE}_Expanded_5um_cell_contour_coords.csv"

    elif [[ "${USER_DATA_DIR}" == gs://* ]]; then
      echo "Detected Google Cloud Storage path, using gcloud storage..."

      # Find and download OME-TIFF.
      OME_FILE=$(
        gcloud storage ls "${USER_DATA_DIR%/}/results/${SAMPLE}/" |
          grep '\.ome\.tiff$' |
          head -n1
      )

      if [[ -z "${OME_FILE}" ]]; then
        echo "ERROR: No OME-TIFF found under ${USER_DATA_DIR%/}/results/${SAMPLE}/" >&2
        exit 2
      fi

      gcloud storage cp \
        "${OME_FILE}" \
        "${IN_DIR}/${SAMPLE}.ome.tiff"

      # Download the 10x matrix while preserving the directory expected by
      # IST_Landscape_Pre-process.py.
      gcloud storage rsync -r \
        "${USER_DATA_DIR%/}/results/${SAMPLE}/${CELL_BINNED_DIR}/" \
        "${LOCAL_CELL_BINNED_DIR}/"

      gcloud storage cp \
        "${USER_DATA_DIR%/}/intermediate_results/stats/sample_prep_stats_sample.csv" \
        "${IN_DIR}/"

      # Find and download contour CSV.
      CSV_FILE=$(
        gcloud storage ls "${USER_DATA_DIR%/}/results/${SAMPLE}/" |
          grep '5um_cell_contour_coords\.csv$' |
          head -n1
      )

      if [[ -z "${CSV_FILE}" ]]; then
        echo "ERROR: No 5um cell contour CSV found under ${USER_DATA_DIR%/}/results/${SAMPLE}/" >&2
        exit 2
      fi

      gcloud storage cp \
        "${CSV_FILE}" \
        "${IN_DIR}/${SAMPLE}_Expanded_5um_cell_contour_coords.csv"

    else
      echo "ERROR: data_dir must start with s3:// or gs://" >&2
      exit 1
    fi

    # Validate the files required by scanpy.read_10x_mtx().
    MATRIX_PATH="${LOCAL_CELL_BINNED_DIR}/matrix.mtx.gz"
    FEATURES_PATH="${LOCAL_CELL_BINNED_DIR}/features.tsv.gz"
    BARCODES_PATH="${LOCAL_CELL_BINNED_DIR}/barcodes.tsv.gz"

    if [[ ! -f "${MATRIX_PATH}" ]]; then
      echo "ERROR: Missing matrix file: ${MATRIX_PATH}" >&2
      find "${IN_DIR}" -maxdepth 3 -type f -print >&2
      exit 2
    fi

    if [[ ! -f "${FEATURES_PATH}" ]]; then
      echo "ERROR: Missing features file: ${FEATURES_PATH}" >&2
      find "${IN_DIR}" -maxdepth 3 -type f -print >&2
      exit 2
    fi

    if [[ ! -f "${BARCODES_PATH}" ]]; then
      echo "ERROR: Missing barcodes file: ${BARCODES_PATH}" >&2
      find "${IN_DIR}" -maxdepth 3 -type f -print >&2
      exit 2
    fi

    echo "Downloaded input files:"
    find "${IN_DIR}" -maxdepth 3 -type f -print

    echo "Running celldega..."

    python3 /opt/IST_Landscape_Pre-process.py \
      --data_dir "${DATA_ROOT}" \
      --sample "${SAMPLE}" \
      --path_landscape_files "${OUTDIR}" \
      --tile_size ~{tile_size} \
      --image_scale ~{image_scale} \
      --jitter ~{jitter}

    echo "Syncing outputs back to bucket..."

    if [[ "${USER_OUTPUT_DIR}" == s3://* ]]; then
      aws s3 sync \
        "${OUTDIR}/" \
        "${USER_OUTPUT_DIR%/}/" \
        --no-progress

    elif [[ "${USER_OUTPUT_DIR}" == gs://* ]]; then
      gcloud storage rsync -r \
        "${OUTDIR}/" \
        "${USER_OUTPUT_DIR%/}/"

    else
      echo "ERROR: bucket_path_landscape_files must start with s3:// or gs://" >&2
      exit 1
    fi

    echo "Done."
  >>>

  runtime {
    docker: celldega_docker_image
    memory: "400 GB"
    disks: "local-disk 200 HDD"
    preemptible: 0
    continueOnReturnCode: 0
  }
}