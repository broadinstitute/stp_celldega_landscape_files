version 1.0

import "generate_landscape_files_ist.wdl" as ist
import "generate_landscape_files_visium_hd.wdl" as visium_hd

workflow LandscapeFiles {
  input {
    String sample
    String data_dir
    String bucket_path_landscape_files
    Int tile_size = 250
    String technology
    String? image_file_name
    use_dummy_clusters = False
    bin_size = 2
    jitter = 1
    image_scale = 1.0

  }

  if (technology == "Xenium" || technology == "MERSCOPE") {
    call ist.generate_landscape_files {
      input:
        sample = sample,
        data_dir = data_dir,
        bucket_path_landscape_files = bucket_path_landscape_files,
        tile_size = tile_size
    }
  }

  if (technology == "Visium-HD") {
    call visium_hd.generate_landscape_files {
      input:
        sample = sample,
        data_dir = data_dir,
        bucket_path_landscape_files = bucket_path_landscape_files,
        tile_size = tile_size,
        image_file_name = image_file_name,
        use_dummy_clusters = use_dummy_clusters,
        bin_size = bin_size,
        jitter = jitter,
        image_scale = image_scale
    }
  }
}
