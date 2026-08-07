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

    CELL_BINNED_DIR="${IN_DIR}/${SAMPLE}_cell_binned"
    RAW_DIR="${IN_DIR}/${SAMPLE}_raw"

    mkdir -p \
      "${IN_DIR}" \
      "${OUTDIR}" \
      "${CELL_BINNED_DIR}" \
      "${RAW_DIR}"

    echo "Checking data_dir source: ${USER_DATA_DIR}"

    if [[ "${USER_DATA_DIR}" == s3://* ]]; then
      echo "Detected AWS S3 path."

      # Get the S3 bucket name.
      S3_BUCKET="${USER_DATA_DIR#s3://}"
      S3_BUCKET="${S3_BUCKET%%/*}"

      echo "Searching recursively under ${USER_DATA_DIR}..."

      mapfile -t S3_KEYS < <(
        aws s3 ls "${USER_DATA_DIR%/}/" --recursive |
          awk '{print $4}'
      )

      #
      # Find OME-TIFF
      #
      OME_KEY=$(
        printf '%s\n' "${S3_KEYS[@]}" |
          grep -F "${SAMPLE}" |
          grep '\.ome\.tiff$' |
          head -n1 || true
      )

      if [[ -z "${OME_KEY}" ]]; then
        echo "ERROR: Could not find an OME-TIFF for ${SAMPLE}." >&2
        exit 2
      fi

      echo "Found OME-TIFF:"
      echo "  s3://${S3_BUCKET}/${OME_KEY}"

      aws s3 cp \
        "s3://${S3_BUCKET}/${OME_KEY}" \
        "${IN_DIR}/${SAMPLE}.ome.tiff"


      #
      # Find sample_prep_stats_sample.csv
      #
      STATS_KEY=$(
        printf '%s\n' "${S3_KEYS[@]}" |
          grep 'sample_prep_stats_sample\.csv$' |
          head -n1 || true
      )

      if [[ -z "${STATS_KEY}" ]]; then
        echo "ERROR: Could not find sample_prep_stats_sample.csv." >&2
        exit 2
      fi

      echo "Found sample prep stats:"
      echo "  s3://${S3_BUCKET}/${STATS_KEY}"

      aws s3 cp \
        "s3://${S3_BUCKET}/${STATS_KEY}" \
        "${IN_DIR}/sample_prep_stats_sample.csv"


      #
      # Find contour CSV
      #
      CSV_KEY=$(
        printf '%s\n' "${S3_KEYS[@]}" |
          grep -F "${SAMPLE}" |
          grep '5um_cell_contour_coords\.csv$' |
          head -n1 || true
      )

      if [[ -z "${CSV_KEY}" ]]; then
        echo "ERROR: Could not find 5um cell contour CSV for ${SAMPLE}." >&2
        exit 2
      fi

      echo "Found contour CSV:"
      echo "  s3://${S3_BUCKET}/${CSV_KEY}"

      aws s3 cp \
        "s3://${S3_BUCKET}/${CSV_KEY}" \
        "${IN_DIR}/${SAMPLE}_Expanded_5um_cell_contour_coords.csv"


      #
      # Find directory ending in "_cell_binned"
      #
      CELL_BINNED_PREFIX=$(
        printf '%s\n' "${S3_KEYS[@]}" |
          grep -F "${SAMPLE}" |
          sed -n 's#^\(.*[^/]*_cell_binned\)/.*#\1#p' |
          sort -u |
          head -n1 || true
      )

      if [[ -z "${CELL_BINNED_PREFIX}" ]]; then
        echo "ERROR: Could not find a directory ending in _cell_binned for ${SAMPLE}." >&2
        exit 2
      fi

      echo "Found cell-binned directory:"
      echo "  s3://${S3_BUCKET}/${CELL_BINNED_PREFIX}/"

      aws s3 sync \
        "s3://${S3_BUCKET}/${CELL_BINNED_PREFIX}/" \
        "${CELL_BINNED_DIR}/" \
        --no-progress


      #
      # Find directory ending in "_raw"
      #
      RAW_PREFIX=$(
        printf '%s\n' "${S3_KEYS[@]}" |
          grep -F "${SAMPLE}" |
          sed -n 's#^\(.*[^/]*_raw\)/.*#\1#p' |
          sort -u |
          head -n1 || true
      )

      if [[ -z "${RAW_PREFIX}" ]]; then
        echo "ERROR: Could not find a directory ending in _raw for ${SAMPLE}." >&2
        exit 2
      fi

      echo "Found raw directory:"
      echo "  s3://${S3_BUCKET}/${RAW_PREFIX}/"

      aws s3 sync \
        "s3://${S3_BUCKET}/${RAW_PREFIX}/" \
        "${RAW_DIR}/" \
        --no-progress


    elif [[ "${USER_DATA_DIR}" == gs://* ]]; then
      echo "Detected Google Cloud Storage path."

      echo "Searching recursively under ${USER_DATA_DIR}..."

      mapfile -t GCS_FILES < <(
        gcloud storage ls \
          --recursive \
          "${USER_DATA_DIR%/}/"
      )


      #
      # Find OME-TIFF
      #
      OME_FILE=$(
        printf '%s\n' "${GCS_FILES[@]}" |
          grep -F "${SAMPLE}" |
          grep '\.ome\.tiff$' |
          head -n1 || true
      )

      if [[ -z "${OME_FILE}" ]]; then
        echo "ERROR: Could not find an OME-TIFF for ${SAMPLE}." >&2
        exit 2
      fi

      echo "Found OME-TIFF:"
      echo "  ${OME_FILE}"

      gcloud storage cp \
        "${OME_FILE}" \
        "${IN_DIR}/${SAMPLE}.ome.tiff"


      #
      # Find sample_prep_stats_sample.csv
      #
      STATS_FILE=$(
        printf '%s\n' "${GCS_FILES[@]}" |
          grep 'sample_prep_stats_sample\.csv$' |
          head -n1 || true
      )

      if [[ -z "${STATS_FILE}" ]]; then
        echo "ERROR: Could not find sample_prep_stats_sample.csv." >&2
        exit 2
      fi

      echo "Found sample prep stats:"
      echo "  ${STATS_FILE}"

      gcloud storage cp \
        "${STATS_FILE}" \
        "${IN_DIR}/sample_prep_stats_sample.csv"


      #
      # Find contour CSV
      #
      CSV_FILE=$(
        printf '%s\n' "${GCS_FILES[@]}" |
          grep -F "${SAMPLE}" |
          grep '5um_cell_contour_coords\.csv$' |
          head -n1 || true
      )

      if [[ -z "${CSV_FILE}" ]]; then
        echo "ERROR: Could not find 5um cell contour CSV for ${SAMPLE}." >&2
        exit 2
      fi

      echo "Found contour CSV:"
      echo "  ${CSV_FILE}"

      gcloud storage cp \
        "${CSV_FILE}" \
        "${IN_DIR}/${SAMPLE}_Expanded_5um_cell_contour_coords.csv"


      #
      # Find directory ending in "_cell_binned"
      #
      CELL_BINNED_SOURCE=$(
        printf '%s\n' "${GCS_FILES[@]}" |
          grep -F "${SAMPLE}" |
          sed -n 's#^\(gs://.*[^/]*_cell_binned\)/.*#\1#p' |
          sort -u |
          head -n1 || true
      )

      if [[ -z "${CELL_BINNED_SOURCE}" ]]; then
        echo "ERROR: Could not find a directory ending in _cell_binned for ${SAMPLE}." >&2
        exit 2
      fi

      echo "Found cell-binned directory:"
      echo "  ${CELL_BINNED_SOURCE}/"

      gcloud storage rsync -r \
        "${CELL_BINNED_SOURCE}/" \
        "${CELL_BINNED_DIR}/"


      #
      # Find directory ending in "_raw"
      #
      RAW_SOURCE=$(
        printf '%s\n' "${GCS_FILES[@]}" |
          grep -F "${SAMPLE}" |
          sed -n 's#^\(gs://.*[^/]*_raw\)/.*#\1#p' |
          sort -u |
          head -n1 || true
      )

      if [[ -z "${RAW_SOURCE}" ]]; then
        echo "ERROR: Could not find a directory ending in _raw for ${SAMPLE}." >&2
        exit 2
      fi

      echo "Found raw directory:"
      echo "  ${RAW_SOURCE}/"

      gcloud storage rsync -r \
        "${RAW_SOURCE}/" \
        "${RAW_DIR}/"

    else
      echo "ERROR: data_dir must start with s3:// or gs://" >&2
      exit 1
    fi


    #
    # Show exactly what was downloaded.
    #
    echo "Downloaded input files:"
    find "${IN_DIR}" -type f -print


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