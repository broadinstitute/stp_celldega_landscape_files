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

    echo "Copying input data from GCS..."
    gcloud storage cp -r "${data_dir}" "./data_input"

    echo "Running celldega..."
    python3 <<EOF
import celldega as dega

dega.pre.main(
    sample="${sample}",
    data_root_dir="data_input",
    tile_size=${tile_size},
    path_landscape_files="${path_landscape_files}",
    use_int_index=True,
)
EOF
  >>>

  output {
    Array[File] landscape_files = glob("~{path_landscape_files}/**")
  }

  runtime {
    docker: "jishar7/celldega_landscape_files:sha256:c623daf895daf524f81a50dc46f76a9feb30737758d9f6b954b7863339ade10b"
    memory: "200 GB"
    disks: "local-disk 200 HDD"
    preemptible: 0
    continueOnReturnCode: 0
  }
}