version 1.0

workflow LandscapeFiles {

  input {
    String sample
    String data_dir
    String landscape_files_dir_name
    Int tile_size = 250
  }

  call generate_landscape_files {
    input:
      sample = sample,
      data_dir = data_dir,
      landscape_files_dir_name = landscape_files_dir_name,
      tile_size = tile_size
  }
}

task generate_landscape_files {

  input {
    String sample
    String data_dir
    String landscape_files_dir_name
    Int tile_size
  }

  command <<<
    #!/bin/bash
    set -euo pipefail

    echo "Copying input data from GCS..."
    gcloud storage cp -r "~{data_dir}/~{sample}" "/cromwell_root/"

    echo "Running celldega..."
    python3 <<'PY'
import celldega as dega

dega.pre.main(
    sample="~{sample}",
    data_root_dir="/cromwell_root",
    tile_size=~{tile_size},
    path_landscape_files="/cromwell_root/~{landscape_files_dir_name}",
    use_int_index=True,
)
PY

  echo "Zipping the entire landscape output directory..."
  tar -czf landscape_files.tar.gz -C "/cromwell_root" "~{landscape_files_dir_name}"
>>>

  output {
    File landscape_archive = "landscape_files.tar.gz"
  }

  runtime {
    docker: "jishar7/celldega_landscape_files@sha256:331483db81cd7646674a6c4a67ca6874cfc477833afd4796a24919a5db62ffbc"
    memory: "200 GB"
    disks: "local-disk 200 HDD"
    preemptible: 0
    continueOnReturnCode: 0
  }
}
