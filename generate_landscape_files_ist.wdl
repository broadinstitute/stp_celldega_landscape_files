version 1.0

task generate_landscape_files {

  input {
    String sample
    String data_dir
    String bucket_path_landscape_files
    Int tile_size = 250
    String celldega_docker_image
    String cleaned_data_dir = sub(sub("~{data_dir}/~{sample}", "//+", "/"), "/+$", "/")
    String cleaned_bucket_path_landscape_files = sub(sub("~{bucket_path_landscape_files}", "//+", "/"), "/+$", "")
  }

  command <<<
    #!/bin/bash
    set -euo pipefail

    echo "Checking data_dir source: ~{cleaned_data_dir}"

    DATA_ROOT="${PWD}"
    OUTDIR="${DATA_ROOT}/landscape_files_temp"
    IN_DIR="${DATA_ROOT}/~{sample}"

    mkdir -p "${IN_DIR}" "${OUTDIR}"

    if [[ ~{cleaned_data_dir} == s3://* ]]; then
      echo "Detected AWS S3 path, using aws s3 sync..."

      echo "source path is ~{cleaned_data_dir}"
      aws s3 ls "~{cleaned_data_dir}"

      aws s3 sync "~{cleaned_data_dir}" "${IN_DIR}/" --exclude "._*" --exclude ".DS_Store"
      echo "${IN_DIR}"
      echo "${OUTDIR}"

      aws s3 ls "${IN_DIR}"

    elif [[ ~{cleaned_data_dir} == gs://* ]]; then
      echo "Detected Google Cloud Storage path, using gcloud storage rsync..."

      gcloud storage rsync -r "~{cleaned_data_dir}" "${IN_DIR}/"

    else
      echo "ERROR: data_dir must start with s3:// or gs://"
      exit 1
    fi

    export DATA_ROOT OUTDIR

    echo "Running celldega..."
    python3 <<'PY'
import os
import celldega as dega

dega.pre.main(
    sample="~{sample}",
    data_root_dir=os.environ["DATA_ROOT"],
    tile_size=~{tile_size},
    path_landscape_files=os.environ["OUTDIR"],
    use_int_index=True,
)
PY

    echo "Syncing outputs back to bucket..."

    if [[ ~{cleaned_bucket_path_landscape_files} == s3://* ]]; then
      echo "Detected AWS S3 output bucket, using aws s3 sync..."
      aws s3 sync "${OUTDIR}/" "~{cleaned_bucket_path_landscape_files}/~{sample}/" --no-progress

    elif [[ ~{cleaned_bucket_path_landscape_files} == gs://* ]]; then
      echo "Detected GCS output bucket, using gcloud storage rsync..."
      gcloud storage rsync -r "${OUTDIR}/" "~{cleaned_bucket_path_landscape_files}/~{sample}/"

    else
      echo "ERROR: cleaned_bucket_path_landscape_files must start with s3:// or gs://"
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

