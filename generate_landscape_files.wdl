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
    docker: "jishar7/celldega_landscape_files@sha256:d246aabee465f628cec4396b2521d45b23d0b9017e7498ffc5bb4f174236ce6c"
    memory: "200 GB"
    disks: "local-disk 200 HDD"
    preemptible: 0
    continueOnReturnCode: 0
  }
}
