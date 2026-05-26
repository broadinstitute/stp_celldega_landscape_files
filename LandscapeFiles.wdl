version 1.0

import "generate_landscape_files_ist.wdl" as ist
import "generate_landscape_files_visium_hd.wdl" as visium_hd
import "generate_landscape_files_I_ST.wdl" as I_ST

workflow LandscapeFiles {
  input {
    String dataset_name = ""
    String project_id = ""
    String input_data_dir = ""
    String output_dega_files_dir = ""
    Int tile_size = 500
    String technology
    String instrument_run = ""
    String image_file_path = ""
    Boolean use_dummy_clusters = false
    Int bin_size = 2
    Int jitter = 1
    Float image_scale = 1.0
    String image_tile_layer = "all"
    String celldega_docker_image = "jishar7/celldega_landscape_files:main_V1.0"
  }

  Boolean use_instrument_paths = dataset_name != "" && instrument_run != "" && project_id != ""

  String normalized_technology =
    if technology == "Xenium" then "xenium"
    else if technology == "MERSCOPE" then "merscope"
    else if technology == "Visium-HD" then "visium_hd"
    else if technology == "IST" then "ist"
    else technology

  String resolved_input_data_dir =
    if use_instrument_paths
    then "s3://manifold-ai-sc-broad-prod-platform-storage/research/projects/~{project_id}/data/instrument_data/~{normalized_technology}/~{instrument_run}"
    else input_data_dir

  String resolved_output_dega_files_dir =
    if use_instrument_paths
    then "s3://manifold-ai-sc-broad-prod-platform-storage/research/projects/~{project_id}/data/DegaFiles"
    else output_dega_files_dir

  if (technology == "Xenium" || technology == "MERSCOPE") {
    call ist.generate_landscape_files as ist_run {
      input:
        input_data_dir = resolved_input_data_dir,
        output_dega_files_dir = resolved_output_dega_files_dir,
        tile_size = tile_size,
        celldega_docker_image = celldega_docker_image,
        image_tile_layer = image_tile_layer
    }
  }

  if (technology == "Visium-HD") {
    call visium_hd.generate_landscape_files as visium_run {
      input:
        input_data_dir = resolved_input_data_dir,
        output_dega_files_dir = resolved_output_dega_files_dir,
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
        input_data_dir = resolved_input_data_dir,
        output_dega_files_dir = resolved_output_dega_files_dir,
        tile_size = tile_size,
        image_scale = image_scale,
        jitter = jitter,
        celldega_docker_image = celldega_docker_image
    }
  }
}