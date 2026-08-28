import argparse
import json
import os
import re
from collections import defaultdict
from pathlib import Path

import celldega as dega
import geopandas as gpd
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import pyarrow.parquet as pq
import tifffile
from matplotlib.colors import to_hex
from shapely.geometry import Polygon

import xml.etree.ElementTree as ET


# ============================================================
# TILE-NAMING HELPERS
#
# The celldega viewer requests tiles using an ABSOLUTE grid:
# tileX = floor(absolute_micron_x / tile_size), tileY = floor(absolute_micron_y
# / tile_size) -- tile (0, 0) always means the micron range [0, tile_size),
# never "wherever this sample's own data happens to start". The previous
# version of this script (and celldega's own write_pseudotranscripts_from_sbg)
# computed a per-sample tile_bounds min/max from the data, which is correct
# for deciding how big a grid to allocate, but then wrote files using a LOCAL
# index starting at (0, 0) relative to that per-sample origin instead of the
# absolute index. Every tile ends up misnamed by a constant (offset_i,
# offset_j), which the viewer has no way to know about: polygons/transcripts
# render shifted, and the far edge of the tissue -- where the local grid runs
# out of tiles before the absolute grid does -- goes blank.
# ============================================================

def to_absolute_tile_bounds(min_val, max_val, tile_size):
    """Returns (abs_min, abs_max) tile-grid edges, in the same absolute
    coordinate space the viewer uses, guaranteed to strictly contain
    [min_val, max_val].

    `abs_max` is deliberately `floor(max_val / tile_size) * tile_size +
    tile_size` (i.e. always one tile size ABOVE where max_val falls) rather
    than `ceil(max_val / tile_size) * tile_size`. When max_val lands exactly
    on a tile boundary, ceil() returns that same boundary value, and a
    `< abs_max` membership test then excludes the point sitting exactly on
    it -- a real (if rare) way to silently drop the single most extreme
    cell/transcript in a sample.
    """

    abs_min = int(np.floor(min_val / tile_size) * tile_size)
    abs_max = int(np.floor(max_val / tile_size) * tile_size + tile_size)
    return abs_min, abs_max


def rename_local_tiles_to_absolute(tile_dir, prefix, offset_i, offset_j):
    """Renames every already-written '{prefix}_tile_{i}_{j}.parquet' file in
    tile_dir from a local (0-based) index to the absolute index the viewer
    expects, by adding (offset_i, offset_j).

    Used after celldega.pre.write_pseudotranscripts_from_sbg, which writes
    transcript tiles using its own internal local indexing that we do not
    control. Uses a two-phase rename (via a temporary suffix) so that no
    destination filename can ever collide with a not-yet-processed source
    filename, regardless of offset sign/magnitude.
    """

    if offset_i == 0 and offset_j == 0:
        return 0

    pattern = re.compile(rf"^{re.escape(prefix)}_tile_(\d+)_(\d+)\.parquet$")
    tile_dir = Path(tile_dir)
    files = [f for f in tile_dir.iterdir() if pattern.match(f.name)]

    temp_entries = []
    for f in files:
        m = pattern.match(f.name)
        i, j = int(m.group(1)), int(m.group(2))
        tmp_path = f.with_name(f.name + ".tmpmove")
        f.rename(tmp_path)
        temp_entries.append((tmp_path, i, j))

    for tmp_path, i, j in temp_entries:
        new_i, new_j = i + offset_i, j + offset_j
        final_path = tmp_path.with_name(f"{prefix}_tile_{new_i}_{new_j}.parquet")
        tmp_path.rename(final_path)

    return len(temp_entries)


def count_rows_in_tiles(tile_dir, prefix):
    """Fast row-count total across all '{prefix}_tile_*.parquet' files,
    reading only parquet footers (no data pages) for speed.
    """

    pattern = re.compile(rf"^{re.escape(prefix)}_tile_(-?\d+)_(-?\d+)\.parquet$")
    tile_dir = Path(tile_dir)
    total = 0
    for f in tile_dir.iterdir():
        if pattern.match(f.name):
            total += pq.ParquetFile(f).metadata.num_rows
    return total


# ============================================================
# UNIT-SCALE (nm vs um) DETECTION
#
# The previous heuristic ("is the raw coordinate's median more than 100x the
# Global_left/Global_top offset?") silently misfires whenever that offset
# happens to be small (e.g. a sample placed near the stage origin), because
# almost any micron-scale value will then exceed a tiny offset x100 too --
# triggering a bogus /1000 conversion on data that was already correct.
#
# Instead we settle the question empirically: apply each candidate scale
# factor, transform to final image-pixel coordinates, and check which
# interpretation actually lands the data inside the image. This is
# self-validating and does not depend on the offset's magnitude at all, so it
# holds regardless of where a given sample sits on the stage.
# ============================================================

def select_unit_scale(
    raw_x,
    raw_y,
    global_left,
    global_top,
    high_res_scale,
    image_width,
    image_height,
    label,
    candidate_factors=(1.0, 1.0 / 1000.0),
    max_points=20000,
    min_acceptable_fraction=0.5,
    margin_fraction=0.02,
):
    """Picks whichever candidate factor (applied to raw_x/raw_y before the
    Global_left/Global_top/high_res_scale transform) places the largest
    fraction of points inside the known image bounds, and returns that
    factor. Raises if no candidate is remotely plausible, rather than
    guessing.
    """

    raw_x = np.asarray(raw_x, dtype=float)
    raw_y = np.asarray(raw_y, dtype=float)

    finite = np.isfinite(raw_x) & np.isfinite(raw_y)
    n_non_finite = int((~finite).sum())
    if n_non_finite:
        print(
            f"{label}: {n_non_finite:,} of {len(raw_x):,} raw coordinate rows "
            "are non-finite (NaN/inf) and are excluded from unit-scale detection "
            "(they cannot be placed under any scale and will be reported "
            "separately as dropped)."
        )
    raw_x = raw_x[finite]
    raw_y = raw_y[finite]

    if len(raw_x) == 0:
        raise ValueError(f"{label}: no finite raw coordinates to base unit-scale detection on.")

    if len(raw_x) > max_points:
        rng = np.random.default_rng(0)
        idx = rng.choice(len(raw_x), size=max_points, replace=False)
        raw_x = raw_x[idx]
        raw_y = raw_y[idx]

    x_lo = -margin_fraction * image_width
    x_hi = (1 + margin_fraction) * image_width
    y_lo = -margin_fraction * image_height
    y_hi = (1 + margin_fraction) * image_height

    results = []
    for factor in candidate_factors:
        x = (raw_x * factor - global_left) * high_res_scale
        y = (raw_y * factor - global_top) * high_res_scale
        inside = (x >= x_lo) & (x <= x_hi) & (y >= y_lo) & (y <= y_hi)
        results.append((factor, float(inside.mean())))

    factor, fraction = max(results, key=lambda r: r[1])

    if fraction < min_acceptable_fraction:
        detail = ", ".join(f"factor={f} -> {frac:.1%} inside image" for f, frac in results)
        raise ValueError(
            f"{label}: could not confidently determine the raw coordinate unit "
            f"scale -- no candidate places a majority of points inside the "
            f"image bounds ({detail}). Refusing to guess; inspect this "
            f"sample's raw coordinates manually."
        )

    print(
        f"{label}: selected unit scale factor={factor} "
        f"({fraction:.1%} of sampled points land inside the image bounds)"
    )
    return factor


def main(
    data_dir,
    sample,
    path_landscape_files,
    tile_size=500,
    image_scale=1.0,
    jitter=1,
):
    # ------------------------------------------------------------
    # helper functions
    # ------------------------------------------------------------

    def make_polygon(row):
        try:
            poly = Polygon(zip(row["vertex_x"], row["vertex_y"]))
            if poly.is_empty or not poly.is_valid or len(poly.exterior.coords) < 3:
                return None
            return poly
        except Exception:
            return None

    def simple_format(geometry, image_scale):
        # factor in scaling
        return [
            [[coord[0] / image_scale, coord[1] / image_scale] for coord in polygon]
            for polygon in geometry
        ]

    def transform_polygon(polygon):
        exterior_coords = polygon.exterior.coords
        original_format_coords = np.array(
            [np.array(coord) for coord in exterior_coords]
        )
        return np.array([original_format_coords], dtype=object)

    def make_column_names_unique_fast(df):
        counts = defaultdict(int)
        used = set()
        new_cols = []

        for col in df.columns:
            if col not in used:
                new_cols.append(col)
                used.add(col)
                counts[col] += 1
            else:
                while True:
                    new_name = f"{col}_{counts[col]}"
                    counts[col] += 1
                    if new_name not in used:
                        new_cols.append(new_name)
                        used.add(new_name)
                        break

        df.columns = new_cols
        return df

    def is_numeric_field(value):
        # Barcode coordinates may be integers ("cell1:12200:38104") or decimals
        # ("SBC:1323.506:44874.962"), so str.isdigit() is not enough.
        try:
            float(value)
        except ValueError:
            return False
        return True

    print(f"Celldega version: {dega.__version__}")

    image_tile_layer = "h&e"
    suffix = ".webp[Q=100]"

    path_landscape_files = path_landscape_files + "/" + sample
    os.makedirs(path_landscape_files, exist_ok=True)
    path_landscape_files_p = Path(path_landscape_files)

    print("Processing Image...")

    # Image
    img_file_path = f"{data_dir}/{sample}/{sample}.ome.tiff"

    with tifffile.TiffFile(img_file_path) as tif:
        series = tif.series[0]
        image_data = series.asarray()
        root = ET.fromstring(tif.ome_metadata)

        pixels = root.find(".//{*}Image[@ID='Image:RegImage_20x_pyramid']/{*}Pixels")
        physical_size_x = float(pixels.attrib["PhysicalSizeX"])
        physical_size_y = float(pixels.attrib.get("PhysicalSizeY", physical_size_x))
        if not np.isclose(physical_size_x, physical_size_y, rtol=0.01):
            print(
                f"WARNING: PhysicalSizeX ({physical_size_x}) and PhysicalSizeY "
                f"({physical_size_y}) differ by more than 1%; this pipeline "
                "assumes square pixels and uses PhysicalSizeX only."
            )
        scaling_factor = physical_size_x / 1000

        image_width = int(pixels.attrib["SizeX"])
        image_height = int(pixels.attrib["SizeY"])

    high_res_scale = 1 / scaling_factor

    tifffile.imwrite(
        path_landscape_files + "/output_regular.tif",
        image_data,
        compression=None,
    )

    image_png = dega.pre._convert_to_png(path_landscape_files + "/output_regular.tif")

    dega.pre.make_deepzoom_pyramid(
        image_png,
        path_landscape_files + "/pyramid_images/",
        image_tile_layer,
        suffix=suffix,
    )

    print("Processing Cells...")

    gc = pd.read_csv(
        f"{data_dir}/{sample}/sample_prep_stats_sample.csv",
        index_col=0,
    )

    if sample not in gc.index:
        raise ValueError(
            f"'{sample}' not found in sample_prep_stats_sample.csv -- cannot "
            "determine Global_left/Global_top offsets for this sample."
        )

    global_left = gc.loc[sample, "Global_left"]
    global_top = gc.loc[sample, "Global_top"]

    # Segmented Cells
    poly = pd.read_csv(f"{data_dir}/{sample}/{sample}_Expanded_5um_cell_contour_coords.csv")

    n_cells_raw = poly["cell_id"].nunique()

    cell_scale_factor = select_unit_scale(
        poly["vertex_x"],
        poly["vertex_y"],
        global_left,
        global_top,
        high_res_scale,
        image_width,
        image_height,
        label="Cell contour coordinates",
    )

    poly["vertex_x"] = poly["vertex_x"] * cell_scale_factor
    poly["vertex_y"] = poly["vertex_y"] * cell_scale_factor

    poly["vertex_x"] = (poly["vertex_x"] - global_left) * high_res_scale
    poly["vertex_y"] = (poly["vertex_y"] - global_top) * high_res_scale

    grouped = poly.groupby("cell_id").agg(list)
    grouped["geometry"] = grouped.apply(make_polygon, axis=1)

    n_invalid_geometry = int(grouped["geometry"].isna().sum())
    if n_invalid_geometry:
        invalid_frac = n_invalid_geometry / len(grouped)
        print(
            f"WARNING: {n_invalid_geometry:,} of {len(grouped):,} cell contours "
            f"({invalid_frac:.2%}) could not form a valid polygon (degenerate "
            "or malformed vertex list) and cannot be placed in any tile."
        )
        if invalid_frac > 0.01:
            raise ValueError(
                f"{invalid_frac:.2%} of cells in {sample} have invalid contour "
                "geometry -- this is high enough to indicate an upstream data "
                "problem rather than a handful of one-off artifacts. Aborting "
                "instead of silently dropping them; inspect "
                f"{sample}_Expanded_5um_cell_contour_coords.csv."
            )
        grouped = grouped[grouped["geometry"].notna()]

    cells = gpd.GeoDataFrame(grouped, geometry="geometry")[["geometry"]]

    cells["NEW_GEOMETRY"] = cells["geometry"].apply(lambda poly: transform_polygon(poly))
    cells["GEOMETRY"] = cells["NEW_GEOMETRY"].apply(lambda x: simple_format(x, image_scale))
    cells["polygon"] = cells["GEOMETRY"].apply(lambda x: Polygon(x[0]))

    gdf_cells = gpd.GeoDataFrame(geometry=cells["polygon"])
    gdf_cells["center_x"] = gdf_cells.centroid.x
    gdf_cells["center_y"] = gdf_cells.centroid.y

    n_cells_kept = len(gdf_cells)
    print(
        f"Cells: {n_cells_raw:,} contours in input -> {n_cells_kept:,} with "
        f"valid geometry ({n_cells_raw - n_cells_kept:,} excluded above)."
    )

    # Absolute (viewer-compatible) cell tile bounds, fencepost-safe.
    cell_x_min_abs, cell_x_max_abs = to_absolute_tile_bounds(
        gdf_cells["center_x"].min(), gdf_cells["center_x"].max(), tile_size
    )
    cell_y_min_abs, cell_y_max_abs = to_absolute_tile_bounds(
        gdf_cells["center_y"].min(), gdf_cells["center_y"].max(), tile_size
    )

    print(
        "Cell tile bounds (absolute):",
        {"x_min": cell_x_min_abs, "x_max": cell_x_max_abs, "y_min": cell_y_min_abs, "y_max": cell_y_max_abs},
    )

    cell_segmentation_dir = path_landscape_files + "/cell_segmentation"
    os.makedirs(cell_segmentation_dir, exist_ok=True)

    gdf_cells.index = "cell" + gdf_cells.index.astype(str)
    cells.index = "cell" + cells.index.astype(str)

    clusters = pd.DataFrame(index=gdf_cells.index.tolist())
    clusters["cluster"] = pd.Series("0", index=gdf_cells.index.tolist(), dtype="string")

    cell_clusters_dir = path_landscape_files + "/cell_clusters"
    os.makedirs(cell_clusters_dir, exist_ok=True)
    clusters.to_parquet(f"{cell_clusters_dir}/cluster.parquet")

    gdf_cells_copy = gdf_cells.copy()
    gdf_cells_copy.reset_index(inplace=True)
    gdf_cells_copy.rename(columns={"cell_id": "name"}, inplace=True)
    gdf_cells_copy["geometry"] = gdf_cells_copy.apply(
        lambda row: [row["center_x"], row["center_y"]], axis=1
    )

    gdf_cells_copy[["name", "geometry"]].to_parquet(
        path_landscape_files + "/cell_metadata.parquet",
        index=False,
    )

    cell_str_to_int_mapping = dega.pre.boundary_tile._get_name_mapping(
        path_landscape_files,
        layer="boundary",
        segmentation="default",
    )

    gdf_cells.index = gdf_cells.index.astype(str).map(cell_str_to_int_mapping)
    cells.index = cells.index.astype(str).map(cell_str_to_int_mapping)

    if gdf_cells.index.isna().any() or cells.index.isna().any():
        raise ValueError(
            "Some cell IDs could not be mapped via "
            "dega.pre.boundary_tile._get_name_mapping -- refusing to write "
            "tiles with unmapped/NaN cell names."
        )

    if cells.index.duplicated().any():
        raise ValueError(
            "Cell-name mapping produced duplicate names for distinct cells -- "
            "refusing to write tiles, as this would silently merge/overwrite "
            "unrelated cells in the same tile."
        )

    # Every cell gets its own tile index computed directly (not via a
    # range-based membership filter), so there is no way for a cell to fall
    # outside the loop's covered range.
    gdf_cells["tile_i"] = np.floor(
        (gdf_cells["center_x"] - cell_x_min_abs) / tile_size
    ).astype(int)
    gdf_cells["tile_j"] = np.floor(
        (gdf_cells["center_y"] - cell_y_min_abs) / tile_size
    ).astype(int)

    n_tile_groups = gdf_cells.groupby(["tile_i", "tile_j"]).ngroups
    print(f"Writing {n_tile_groups:,} cell_segmentation tiles...")

    for (tile_i, tile_j), group in gdf_cells.groupby(["tile_i", "tile_j"]):
        keep_cells = group.index.tolist()

        inst_geo = cells.loc[keep_cells, ["GEOMETRY"]].copy()
        inst_geo["name"] = pd.Series(inst_geo.index.tolist(), index=inst_geo.index.tolist())

        # tile_i/tile_j are already relative to the absolute origin
        # (cell_x_min_abs, cell_y_min_abs), so the absolute filename index is
        # just that origin's own tile index plus tile_i/tile_j.
        abs_i = cell_x_min_abs // tile_size + tile_i
        abs_j = cell_y_min_abs // tile_size + tile_j

        filename = f"{cell_segmentation_dir}/cell_tile_{abs_i}_{abs_j}.parquet"

        inst_geo["GEOMETRY"] = inst_geo["GEOMETRY"].apply(dega.pre._round_nested_coord_list)
        inst_geo[["GEOMETRY", "name"]].to_parquet(filename, index=False)

    n_cells_on_disk = count_rows_in_tiles(cell_segmentation_dir, "cell")
    if n_cells_on_disk != n_cells_kept:
        raise ValueError(
            f"Cell tile row-count check failed for {sample}: {n_cells_kept:,} "
            f"cells had valid geometry but {n_cells_on_disk:,} rows were "
            "written across all cell_segmentation tiles. Some cells were "
            "dropped during tiling."
        )
    print(f"Verified: all {n_cells_on_disk:,} cells with valid geometry are present in cell_segmentation tiles.")

    print("Processing Genes...")

    # Meta Gene
    features = pd.read_csv(
        f"{data_dir}/{sample}/{sample}_cell_binned/features.tsv.gz",
        sep="\t",
        header=None,
        compression="gzip",
    )

    list_genes = features[1].tolist()
    meta_gene = pd.DataFrame(index=list_genes)

    palettes = [plt.get_cmap(name).colors for name in plt.colormaps() if "tab" in name]
    flat_colors = [color for palette in palettes for color in palette]
    flat_colors_hex = [to_hex(color) for color in flat_colors]

    colors = [
        flat_colors_hex[i % len(flat_colors_hex)] if "Blank" not in gene else "#FFFFFF"
        for i, gene in enumerate(list_genes)
    ]

    ser_color = pd.Series(colors, index=list_genes)

    meta_gene["mean"] = pd.Series(100, index=list_genes)
    meta_gene["std"] = pd.Series(10, index=list_genes)
    meta_gene["max"] = pd.Series(100, index=list_genes)
    meta_gene["non-zero"] = pd.Series(0.5, index=list_genes)
    meta_gene["color"] = ser_color

    meta_gene.to_parquet(path_landscape_files + "/meta_gene.parquet")

    print("Saving Landscape Parameters...")

    max_pyramid_zoom = dega.pre.get_max_zoom_level(
        path_landscape_files + f"/pyramid_images/{image_tile_layer}_files"
    )

    landscape_parameters = {
        "technology": "IST",
        "segmentation_approach": ["default"],
        "max_pyramid_zoom": max_pyramid_zoom,
        "tile_size": tile_size,
        "image_info": [
            {
                "name": image_tile_layer,
                "button_name": image_tile_layer.upper(),
                "color": [0, 0, 255],
            }
        ],
        "image_format": ".webp",
        "use_int_index": True,
        "use_row_groups": False,
    }

    with open(path_landscape_files + "/landscape_parameters.json", "w") as f:
        json.dump(landscape_parameters, f, indent=2)

    print("Saving Clusters...")

    meta_cluster = pd.DataFrame()
    meta_cluster.loc["0", "color"] = "#ff7f0e"
    meta_cluster.loc["0", "count"] = 1000
    meta_cluster.to_parquet(cell_clusters_dir + "/meta_cluster.parquet")

    print("Processing CBG...")

    path_cbg = f"{data_dir}/{sample}/{sample}_cell_binned/"

    cbg = dega.pre.read_cbg_mtx(path_cbg, technology="IST")
    cbg.index = [x.split(":")[0] for x in cbg.index.tolist()]
    cbg = make_column_names_unique_fast(cbg)

    dega.pre.make_meta_gene(cbg, path_landscape_files + "/meta_gene.parquet")
    dega.pre.save_cbg_gene_parquets("IST", path_landscape_files, cbg, verbose=True)

    print("Processing Jittered Transcripts...")

    sbg = dega.pre.landscape.read_cbg_mtx(
        f"{data_dir}/{sample}/{sample}_raw",
        technology="IST",
        barcodes_name="barcodes",
    )

    coords = sbg.index.tolist()
    tmp = [x.split(":") for x in coords]
    tmp = [[x for x in row if is_numeric_field(x)] for row in tmp]

    df_tmp = pd.DataFrame(tmp, dtype=float)

    raw_x = df_tmp.iloc[:, 1]
    raw_y = df_tmp.iloc[:, 0]

    trx_scale_factor = select_unit_scale(
        raw_x,
        raw_y,
        global_left,
        global_top,
        high_res_scale,
        image_width,
        image_height,
        label="Transcript coordinates",
    )

    df_tmp = df_tmp * trx_scale_factor
    df_tmp.columns = ["y", "x"]

    df_tmp["x"] = (df_tmp["x"] - global_left) * high_res_scale
    df_tmp["y"] = (df_tmp["y"] - global_top) * high_res_scale

    spots = df_tmp

    n_non_finite_spots = int((~np.isfinite(spots["x"]) | ~np.isfinite(spots["y"])).sum())
    if n_non_finite_spots:
        print(
            f"WARNING: {n_non_finite_spots:,} of {len(spots):,} transcript "
            "spots have non-finite coordinates and cannot be placed in any tile."
        )

    print(
        "Transcript coordinate range:",
        f"x={spots['x'].min():.2f} to {spots['x'].max():.2f},",
        f"y={spots['y'].min():.2f} to {spots['y'].max():.2f}",
    )

    gene_str_to_int = dega.pre.boundary_tile._get_name_mapping(
        path_landscape_files,
        layer="transcript",
    )

    trx_x_min_abs, trx_x_max_abs = to_absolute_tile_bounds(
        spots["x"].min(), spots["x"].max(), tile_size
    )
    trx_y_min_abs, trx_y_max_abs = to_absolute_tile_bounds(
        spots["y"].min(), spots["y"].max(), tile_size
    )

    tile_bounds = {
        "x_min": trx_x_min_abs,
        "x_max": trx_x_max_abs,
        "y_min": trx_y_min_abs,
        "y_max": trx_y_max_abs,
    }

    print("Transcript tile bounds (absolute):", tile_bounds)

    # spots and sbg were built from the exact same coords list in the exact
    # same order (spots via string-splitting sbg.index, sbg untouched since),
    # so this reindex is always a trivial identity alignment -- there is no
    # "unmatched row" failure mode to guard against here.
    sbg.reset_index(inplace=True)
    spots.index = sbg.index
    del sbg[0]
    sbg = make_column_names_unique_fast(sbg)

    total_input_transcripts = int(sbg.sparse.to_coo().sum())

    trx_files_path = path_landscape_files + "/transcript_tiles"
    os.makedirs(trx_files_path, exist_ok=True)

    dega.pre.write_pseudotranscripts_from_sbg(
        spots=spots,
        sbg=sbg,
        gene_str_to_int=gene_str_to_int,
        tile_bounds=tile_bounds,
        tile_size=tile_size,
        path_output=trx_files_path,
        jitter=jitter,
        coarse_tile_factor=10,
        rng=np.random.default_rng(),
    )

    trx_offset_i = tile_bounds["x_min"] // tile_size
    trx_offset_j = tile_bounds["y_min"] // tile_size
    n_renamed = rename_local_tiles_to_absolute(
        trx_files_path, "transcripts", trx_offset_i, trx_offset_j
    )
    print(f"Renamed {n_renamed:,} transcript tile files to absolute indices.")

    n_transcripts_on_disk = count_rows_in_tiles(trx_files_path, "transcripts")
    expected_min = total_input_transcripts - n_non_finite_spots
    if n_transcripts_on_disk < expected_min:
        raise ValueError(
            f"Transcript tile row-count check failed for {sample}: expected "
            f"at least {expected_min:,} transcripts on disk (input "
            f"{total_input_transcripts:,}, minus {n_non_finite_spots:,} "
            f"non-finite), but found only {n_transcripts_on_disk:,}. Some "
            "transcripts were dropped during tiling."
        )
    print(
        f"Verified: {n_transcripts_on_disk:,} transcripts on disk "
        f"(input {total_input_transcripts:,}, "
        f"{n_non_finite_spots:,} legitimately unplaceable)."
    )

    print("Done.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="IST-Celldega-LandscapeFiles-Preprocess")

    parser.add_argument("--data_dir", type=str)
    parser.add_argument("--sample", type=str)
    parser.add_argument("--path_landscape_files", type=str)
    parser.add_argument("--tile_size", type=int, default=500)
    parser.add_argument("--image_scale", type=float, default=1.0)
    parser.add_argument("--jitter", type=int, default=1)

    args = parser.parse_args()

    main(
        data_dir=args.data_dir,
        sample=args.sample,
        path_landscape_files=args.path_landscape_files,
        tile_size=args.tile_size,
        image_scale=args.image_scale,
        jitter=args.jitter,
    )
