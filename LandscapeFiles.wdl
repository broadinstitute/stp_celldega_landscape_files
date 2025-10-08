version 1.0

import "generate_landscape_files_ist.wdl" as ist
import "generate_landscape_files_visium_hd.wdl" as visium_hd
import "generate_landscape_files_I_ST.wdl" as I_ST

workflow LandscapeFiles {
  input {
    String sample
    String data_dir
    String bucket_path_landscape_files
    Int tile_size = 500
    String technology
    String image_file_path = ""
    Boolean use_dummy_clusters = false
    Int bin_size = 2
    Int jitter = 2
    Float image_scale = 1.0
    Float scaling_factor = 0.171
    String celldega_docker_image = "jishar7/celldega_landscape_files@sha256:d7b7d31ff17d4e9de6e4b82219d66bce6caae5d73a3a0153ab4ab3191bb7161b"
  }

  if (technology == "Xenium" || technology == "MERSCOPE") {
    call ist.generate_landscape_files as ist_run {
      input:
        sample = sample,
        data_dir = data_dir,
        bucket_path_landscape_files = bucket_path_landscape_files,
        tile_size = tile_size,
        celldega_docker_image = celldega_docker_image
    }
  }

  if (technology == "Visium-HD") {
    call visium_hd.generate_landscape_files as visium_run {
      input:
        sample = sample,
        data_dir = data_dir,
        bucket_path_landscape_files = bucket_path_landscape_files,
        tile_size = tile_size,
        image_file_path = image_file_path,
        use_dummy_clusters = use_dummy_clusters,
        bin_size = bin_size,
        jitter = jitter,
        image_scale = image_scale,
        celldega_docker_image = celldega_docker_image
    }
  }

  if (technology == "IST") {
    call I_ST.generate_landscape_files as I_ST_run {
      input:
        sample = sample,
        data_dir = data_dir,
        bucket_path_landscape_files = bucket_path_landscape_files,
        scaling_factor = scaling_factor,
        tile_size = tile_size,
        image_scale = image_scale,
        jitter = jitter,
        celldega_docker_image = celldega_docker_image
    }
  }
}
