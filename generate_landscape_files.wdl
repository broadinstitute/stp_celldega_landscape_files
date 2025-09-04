version 1.0

workflow LandscapeFiles {

  input {
    String sample
    String data_dir
    String path_landscape_files
    Int tile_size = 250
  }

  call generate_landscape_files {
    input:
      sample = sample,
      data_dir = data_dir,
      path_landscape_files = path_landscape_files,
      tile_size = tile_size
  }
}

task generate_landscape_files {

  input {
    String sample
    String data_dir
    String path_landscape_files
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
    path_landscape_files="/cromwell_root/~{path_landscape_files}",
    use_int_index=True,
)
PY
  >>>

  output {
    Array[File] landscape_files = glob(path_landscape_files + "/**")
  }

  runtime {
    docker: "jishar7/celldega_landscape_files@sha256:331483db81cd7646674a6c4a67ca6874cfc477833afd4796a24919a5db62ffbc"
    memory: "200 GB"
    disks: "local-disk 200 HDD"
    preemptible: 0
    continueOnReturnCode: 0
  }
}
