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
    Int jitter = 1
    Float image_scale = 1.0
    String image_tile_layer = "all"
    # Local disk (GB) for the Xenium/MERSCOPE/Atera task. Defaults to 200, or 500
    # for Atera, whose bundles are large (transcripts + morphology inputs plus
    # ~20 GB of DegaFiles for a WTA region). Set it to override.
    Int? disk_gb
    String celldega_docker_image = "jishar7/celldega_landscape_files:main_V1.10"
  }

  # Atera is a Xenium-class bundle: celldega's pre.main detects it by its
  # experiment.spatial file and uses the Atera readers.
  if (technology == "Xenium" || technology == "MERSCOPE" || technology == "Atera") {
    call ist.generate_landscape_files as ist_run {
      input:
        sample = sample,
        data_dir = data_dir,
        bucket_path_landscape_files = bucket_path_landscape_files,
        tile_size = tile_size,
        celldega_docker_image = celldega_docker_image,
        image_tile_layer = image_tile_layer,
        technology = technology,
        disk_gb = select_first([disk_gb, if technology == "Atera" then 500 else 200])
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
        tile_size = tile_size,
        image_scale = image_scale,
        jitter = jitter,
        celldega_docker_image = celldega_docker_image
    }
  }
}
