version 1.0

workflow LandscapeFiles {

  input {
    String sample
    String data_dir
    String bucket_path_landscape_files
    Int tile_size = 250
  }

  call generate_landscape_files {
    input:
      sample = sample,
      data_dir = data_dir,
      bucket_path_landscape_files = bucket_path_landscape_files,
      tile_size = tile_size
  }
}

task generate_landscape_files {

  input {
    String sample
    String data_dir
    String bucket_path_landscape_files
    Int tile_size
  }

  command <<<
    #!/bin/bash
    set -euo pipefail

    echo "Copying input data from GCS..."
    gcloud storage rsync -r "~{data_dir}/~{sample}/" "/cromwell_root/~{sample}/"

    echo "Running celldega..."
    python3 <<'PY'
import celldega as dega

dega.pre.main(
    sample="~{sample}",
    data_root_dir="/cromwell_root",
    tile_size=~{tile_size},
    path_landscape_files="/cromwell_root/landscape_files_temp",
    use_int_index=True,
)
PY

  gcloud storage rsync -r "/cromwell_root/landscape_files_temp/" "~{bucket_path_landscape_files}/~{sample}/"
>>>

  runtime {
    docker: "jishar7/celldega_landscape_files@sha256:202fb1eaab2ea0a97a00ac40269d51503d52f105c0f0aa737ccd9e0be4093f21"
    memory: "200 GB"
    disks: "local-disk 200 HDD"
    preemptible: 0
    continueOnReturnCode: 0
  }
}
