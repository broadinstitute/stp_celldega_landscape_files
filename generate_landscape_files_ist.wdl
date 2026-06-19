version 1.0

task generate_landscape_files {

  input {
    String input_data_dir
    String output_dega_files_dir
    Int tile_size
    String celldega_docker_image
    String image_tile_layer
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

    elif [[ "${USER_INPUT_DATA_DIR}" == gs://* ]]; then
      echo "Detected Google Cloud Storage path, using gcloud storage rsync..."
      gcloud storage rsync -r "${USER_INPUT_DATA_DIR%/}" "${IN_DIR}/"

    else
      echo "ERROR: input_data_dir must start with s3:// or gs://"
      exit 1
    fi

    if [[ -z "$(find "${IN_DIR}" -type f -print -quit)" ]]; then
      echo "ERROR: No files found under ${USER_INPUT_DATA_DIR}." >&2
      exit 2
    fi

    if [[ "${PROJECT_ID+x}" == "x" ]]; then
      echo "PROJECT_ID exists: ${PROJECT_ID:-<EMPTY>}"
    else
      echo "PROJECT_ID does not exist in environment"
    fi

    export SAMPLE DATA_ROOT OUTDIR

    echo "Running celldega..."
    python3 <<'PY'
import os
import celldega as dega

dega.pre.main(
    sample=os.environ["SAMPLE"],
    data_root_dir=os.environ["DATA_ROOT"],
    tile_size=~{tile_size},
    image_tile_layer="~{image_tile_layer}",
    path_landscape_files=os.environ["OUTDIR"],
    use_int_index=True,
)
PY

    echo "Syncing outputs back to bucket..."

    if [[ "${USER_OUTPUT_DEGA_FILES_DIR}" == s3://* ]]; then
      aws s3 sync "${OUTDIR}/" "${USER_OUTPUT_DEGA_FILES_DIR%/}/${SAMPLE}/" --no-progress

    elif [[ "${USER_OUTPUT_DEGA_FILES_DIR}" == gs://* ]]; then
      gcloud storage rsync -r "${OUTDIR}/" "${USER_OUTPUT_DEGA_FILES_DIR%/}/${SAMPLE}/"

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
  }
}