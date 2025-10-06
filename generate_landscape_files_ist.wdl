version 1.0

task generate_landscape_files {

  input {
    String sample
    String data_dir
    String bucket_path_landscape_files
    Int tile_size = 250
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
      aws s3 sync "${USER_DATA_DIR%/}/${SAMPLE}" "${IN_DIR}/" --exclude "._*" --exclude ".DS_Store"

    elif [[ "${USER_DATA_DIR}" == gs://* ]]; then
      echo "Detected Google Cloud Storage path, using gcloud storage rsync..."
      gcloud storage rsync -r "${USER_DATA_DIR%/}/${SAMPLE}" "${IN_DIR}/"

    else
      echo "ERROR: data_dir must start with s3:// or gs://"
      exit 1
    fi

    if [[ -z "$(find "${IN_DIR}" -type f -print -quit)" ]]; then
      echo "ERROR: No files found under ${USER_DATA_DIR}/${SAMPLE}." >&2
      exit 2
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
    path_landscape_files=os.environ["OUTDIR"],
    use_int_index=True,
)
PY

    echo "Syncing outputs back to bucket..."

    if [[ "${USER_OUTPUT_DIR}" == s3://* ]]; then
      aws s3 sync "${OUTDIR}/" "${USER_OUTPUT_DIR%/}/${SAMPLE}/" --no-progress
    elif [[ "${USER_OUTPUT_DIR}" == gs://* ]]; then
      gcloud storage rsync -r "${OUTDIR}/" "${USER_OUTPUT_DIR%/}/${SAMPLE}/"
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
  }
}
