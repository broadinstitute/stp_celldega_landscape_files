version 1.0
task generate_landscape_files {

  input {
    String sample
    String data_dir
    String bucket_path_landscape_files
    Int tile_size
    String image_file_name
    Boolean use_dummy_clusters
    Int bin_size
    Int jitter
    Float image_scale
    String celldega_docker_image
  }

  command <<<
    #!/bin/bash
    set -euo pipefail

    echo "Checking data_dir source: ~{data_dir}"

    DATA_ROOT="${PWD}"
    OUTDIR="${DATA_ROOT}/landscape_files_temp"
    IN_DIR="${DATA_ROOT}/~{sample}"

    mkdir -p "${IN_DIR}" "${OUTDIR}"

    if [[ "~{data_dir}" == s3://* ]]; then
      echo "Detected AWS S3 path, using aws s3 sync..."

      aws s3 sync "~{data_dir}/~{sample}/" "${IN_DIR}/" --no-progress --exclude "._*" --exclude ".DS_Store"

    elif [[ "~{data_dir}" == gs://* ]]; then
      echo "Detected Google Cloud Storage path, using gcloud storage rsync..."

      gcloud storage rsync -r "~{data_dir}/~{sample}/" "${IN_DIR}/"

    else
      echo "ERROR: data_dir must start with s3:// or gs://"
      exit 1
    fi

    export DATA_ROOT OUTDIR

    echo "Running celldega..."

    python3 /opt/Visium_HD_Landscape_Pre_process.py \
        --data_dir "${DATA_ROOT}" \
        --sample "~{sample}" \
        --image_file_name "~{image_file_name}" \
        --path_landscape_files "${OUTDIR}" \
        --use_dummy_clusters ~{if use_dummy_clusters then 1 else 0} \
        --tile_size ~{tile_size} \
        --bin_size ~{bin_size} \
        --jitter ~{jitter} \
        --image_scale ~{image_scale}

    echo "Syncing outputs back to bucket..."

    if [[ "~{bucket_path_landscape_files}" == s3://* ]]; then
      echo "Detected AWS S3 output bucket, using aws s3 sync..."
      aws s3 sync "${OUTDIR}/" "~{bucket_path_landscape_files}/~{sample}/" --no-progress

    elif [[ "~{bucket_path_landscape_files}" == gs://* ]]; then
      echo "Detected GCS output bucket, using gcloud storage rsync..."
      gcloud storage rsync -r "${OUTDIR}/" "~{bucket_path_landscape_files}/~{sample}/"

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
