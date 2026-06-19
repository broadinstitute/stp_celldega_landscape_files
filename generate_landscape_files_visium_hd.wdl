version 1.0

task generate_landscape_files {

  input {
    String input_data_dir
    String output_dega_files_dir
    Int tile_size
    String image_file_path
    Boolean use_dummy_clusters
    Int bin_size
    Int jitter
    Float image_scale
    String celldega_docker_image
  }

  command <<<
    #!/bin/bash
    set -euo pipefail
    IFS=$'\n\t'

    USER_INPUT_DATA_DIR="~{input_data_dir}"
    USER_OUTPUT_DEGA_FILES_DIR="~{output_dega_files_dir}"

    SAMPLE="$(basename "${USER_INPUT_DATA_DIR%/}")"

    DATA_ROOT="${PWD}"
    OUTDIR="${DATA_ROOT}/landscape_files_temp"
    IN_DIR="${DATA_ROOT}/${SAMPLE}"

    echo "Checking whether output destination already exists..."

    DEST="${USER_OUTPUT_DEGA_FILES_DIR%/}/${SAMPLE}/"

    if [[ "${USER_OUTPUT_DEGA_FILES_DIR}" == s3://* ]]; then
      S3_PATH="${DEST#s3://}"
      S3_BUCKET="${S3_PATH%%/*}"
      S3_PREFIX="${S3_PATH#*/}"

      EXISTING_COUNT="$(
        aws s3api list-objects-v2 \
          --bucket "${S3_BUCKET}" \
          --prefix "${S3_PREFIX}" \
          --max-keys 1 \
          --query 'KeyCount' \
          --output text
      )"

      if [[ "${EXISTING_COUNT}" != "0" ]]; then
        echo "Output already exists at ${DEST}"
        echo "Skipping celldega because landscape files already exist."
        exit 0
      fi

    elif [[ "${USER_OUTPUT_DEGA_FILES_DIR}" == gs://* ]]; then
      if gcloud storage ls -r "${DEST}**" >/tmp/existing_gcs_outputs.txt 2>/dev/null && [[ -s /tmp/existing_gcs_outputs.txt ]]; then
        echo "Output already exists at ${DEST}"
        echo "Skipping celldega because landscape files already exist."
        exit 0
      fi

    else
      echo "ERROR: output_dega_files_dir must start with s3:// or gs://"
      exit 1
    fi

    mkdir -p "${IN_DIR}" "${OUTDIR}"

    echo "Checking input_data_dir source: ${USER_INPUT_DATA_DIR}"
    echo "Detected sample: ${SAMPLE}"

    if [[ "${USER_INPUT_DATA_DIR}" == s3://* ]]; then
      echo "Detected AWS S3 path, using aws s3 sync..."

      aws s3 sync "${USER_INPUT_DATA_DIR%/}" "${IN_DIR}/" --exclude "._*" --exclude ".DS_Store"
      aws s3 cp "~{image_file_path}" "${IN_DIR}/" --no-progress

    elif [[ "${USER_INPUT_DATA_DIR}" == gs://* ]]; then
      echo "Detected Google Cloud Storage path, using gcloud storage rsync..."

      gcloud storage rsync -r "${USER_INPUT_DATA_DIR%/}" "${IN_DIR}/"
      gcloud storage cp "~{image_file_path}" "${IN_DIR}/"

    else
      echo "ERROR: input_data_dir must start with s3:// or gs://"
      exit 1
    fi

    if [[ -z "$(find "${IN_DIR}" -type f -print -quit)" ]]; then
      echo "ERROR: No files found under ${USER_INPUT_DATA_DIR}." >&2
      exit 2
    fi

    image_filename=$(basename "~{image_file_path}")

    echo "Running celldega..."

    python3 /opt/Visium_HD_Landscape_Pre_process.py \
        --data_dir "${DATA_ROOT}" \
        --sample "${SAMPLE}" \
        --image_file_name "${image_filename}" \
        --path_landscape_files "${OUTDIR}" \
        ~{if use_dummy_clusters then "--use_dummy_clusters" else ""} \
        --tile_size ~{tile_size} \
        --bin_size ~{bin_size} \
        --jitter ~{jitter} \
        --image_scale ~{image_scale}

    echo "Syncing outputs back to bucket..."

    if [[ "${USER_OUTPUT_DEGA_FILES_DIR}" == s3://* ]]; then
      aws s3 sync "${OUTDIR}/" "${DEST}" --no-progress

    elif [[ "${USER_OUTPUT_DEGA_FILES_DIR}" == gs://* ]]; then
      gcloud storage rsync -r "${OUTDIR}/" "${DEST}"

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