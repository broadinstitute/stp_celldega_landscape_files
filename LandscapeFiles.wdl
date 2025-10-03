version 1.0

import "generate_landscape_files_ist.wdl" as ist
import "generate_landscape_files_visium_hd.wdl" as visium_hd

workflow LandscapeFiles {
  input {
    String sample
    String data_dir
    String bucket_path_landscape_files
    Int tile_size = 500
    String technology
    String? image_file_name        # optional, no default
    Boolean use_dummy_clusters = false
    Int bin_size = 2
    Int jitter = 2
    Float image_scale = 1.0
    String celldega_docker_image = "jishar7/celldega_landscape_files@sha256:acb6dbe334496c4d1c5d3ed7455c127271fe6cfe60c834642601b889219e3b4f"
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
        image_file_name = image_file_name,
        use_dummy_clusters = use_dummy_clusters,
        bin_size = bin_size,
        jitter = jitter,
        image_scale = image_scale,
        celldega_docker_image = celldega_docker_image
    }
  }
}
