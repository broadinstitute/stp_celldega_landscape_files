import argparse
import json
import os
import tarfile
from collections import defaultdict
from pathlib import Path

import celldega as dega
import fiona
import geopandas as gpd
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import polars as pl
import scanpy as sc
import tifffile
from matplotlib.colors import to_hex
from scipy.sparse import csr_matrix
from shapely.geometry import Point, shape


def main(
    data_dir,
    sample,
    image_file_name,
    path_landscape_files,
    use_dummy_clusters=False,
    tile_size=500,
    bin_size=2,
    jitter=2,
    image_scale=1.0,
):
    # Helper functions
    def decompress_all_tar_gz(path):
        for file in os.listdir(path):
            if file.endswith(".tar.gz"):
                file_path = os.path.join(path, file)
                print(f"Decompressing: {file}")
                with tarfile.open(file_path, "r:gz") as tar:
                    tar.extractall(path)
        print("All files decompressed.")

    def simple_format(geometry, image_scale):
        return [
            [[coord[0] / image_scale, coord[1] / image_scale] for coord in polygon]
            for polygon in geometry
        ]

    def transform_polygon(polygon):
        exterior_coords = polygon.exterior.coords
        original_format_coords = np.array([np.array(coord) for coord in exterior_coords])
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
        df = df.rename_axis("__index_level_0__", axis="columns")
        return df

    path_landscape_files = f"{path_landscape_files}/{sample}_{bin_size}um"

    image_tile_layer = "h&e"
    suffix = ".webp[Q=100]"

    # Make Landscape Files directory
    os.makedirs(path_landscape_files, exist_ok=True)

    # Decompress all .tar.gz files in raw data
    decompress_all_tar_gz(f"{data_dir}/{sample}")

    # Process Image
    img_file_path = f"{data_dir}/{sample}/{image_file_name}"
    with tifffile.TiffFile(img_file_path) as tif:
        series = tif.series[0]
        image_data = series.asarray()

    tifffile.imwrite(
        path_landscape_files + "/output_regular.tif", image_data, compression=None
    )
    image_png = dega.pre._convert_to_png(path_landscape_files + "/output_regular.tif")
    dega.pre.make_deepzoom_pyramid(
        image_png,
        path_landscape_files + "/pyramid_images/",
        image_tile_layer,
        tile_size=tile_size,
        suffix=suffix,
    )

    tile_bounds = {
        "x_min": 0,
        "x_max": image_data.shape[1],
        "y_min": 0,
        "y_max": image_data.shape[0],
    }

    # Process Cells
    features = []
    with fiona.open(
        f"{data_dir}/{sample}/segmented_outputs/cell_segmentations.geojson"
    ) as src:
        for feat in src:
            features.append(
                {
                    "geometry": shape(feat["geometry"]),
                    "cell_id": feat["properties"]["cell_id"],
                }
            )

    cells = gpd.GeoDataFrame(features)
    cells["centroid_x"] = cells.geometry.centroid.x
    cells["centroid_y"] = cells.geometry.centroid.y
    cells["geometry_point"] = cells.apply(
        lambda row: Point(row["centroid_x"], row["centroid_y"]), axis=1
    )
    cells["cell_id"] = cells["cell_id"].astype(str).map(lambda x: f"c-{x}")

    cell_metadata = gpd.GeoDataFrame(
        cells[["cell_id", "geometry_point"]],
        geometry="geometry_point",
        crs="EPSG:4326",
    )
    cell_metadata["geometry"] = cell_metadata["geometry_point"].apply(
        lambda p: [round(p.x, 2), round(p.y, 2)]
    )
    cell_metadata.drop("geometry_point", axis=1, inplace=True)
    cell_metadata.rename(
        columns={"geometry_point": "geometry", "cell_id": "name"}, inplace=True
    )
    cell_metadata.to_parquet(path_landscape_files + "/cell_metadata.parquet")

    cell_clusters_dir = Path(path_landscape_files + "/cell_clusters")
    cell_clusters_dir.mkdir(parents=True, exist_ok=True)

    # Dummy clusters
    if use_dummy_clusters:
        def_clusters = pd.DataFrame(index=cells.index.tolist())
        def_clusters["cluster"] = pd.Series(0, index=cells.index.tolist())
        def_clusters.to_parquet(path_landscape_files + "/cell_clusters/cluster.parquet")

        meta_cluster = pd.DataFrame()
        meta_cluster.loc["0", "color"] = "#ff7f0e"
        meta_cluster.loc["0", "count"] = 1000
        meta_cluster.to_parquet(cell_clusters_dir / "meta_cluster.parquet")

    else:
        def_clusters = pd.read_csv(
            f"{data_dir}/{sample}/segmented_outputs/analysis/clustering/"
            f"gene_expression_graphclust/clusters.csv"
        )
        def_clusters.index = (
            def_clusters["Barcode"].str.extract(r"cellid_0*(\d+)-")[0]
            .astype(int)
            .astype(str)
            .map(lambda x: f"c-{x}")
        )
        def_clusters.drop("Barcode", axis=1, inplace=True)
        def_clusters.rename(columns={"Cluster": "cluster"}, inplace=True)
        def_clusters["cluster"] = def_clusters["cluster"].astype(str)
        def_clusters.index.name = ""

        cells_copy = cells.copy()
        cells_copy.set_index("cell_id", inplace=True)

        def_clusters = def_clusters.reindex(cells_copy.index, fill_value=0)
        def_clusters["cluster"] = def_clusters["cluster"].astype(str)
        def_clusters.to_parquet(cell_clusters_dir / "cluster.parquet")

        meta_cluster = def_clusters["cluster"].value_counts().to_frame(name="count")
        cmap = plt.cm.get_cmap("tab10")
        n_colors = cmap.N
        meta_cluster["color"] = [
            plt.cm.colors.to_hex(cmap(i % n_colors)) for i in range(len(meta_cluster))
        ]
        meta_cluster = meta_cluster[["color", "count"]]
        meta_cluster.index = meta_cluster.index.astype("string")
        meta_cluster.index.name = "__index_level_0__"
        meta_cluster.to_parquet(cell_clusters_dir / "meta_cluster.parquet")

    # Create cell tiles
    cells["GEOMETRY"] = cells["geometry"].apply(lambda poly: transform_polygon(poly))
    cells["GEOMETRY"] = cells["GEOMETRY"].apply(lambda x: simple_format(x, image_scale))
    cells.rename(
        columns={
            "cell_id": "name",
            "centroid_x": "center_x",
            "centroid_y": "center_y",
        },
        inplace=True,
    )
    cells.drop(["geometry", "geometry_point"], axis=1, inplace=True)

    tile_size_x = tile_size
    tile_size_y = tile_size
    x_min, x_max = tile_bounds["x_min"], tile_bounds["x_max"]
    y_min, y_max = tile_bounds["y_min"], tile_bounds["y_max"]

    n_tiles_x = int(np.ceil((x_max - x_min) / tile_size_x))
    n_tiles_y = int(np.ceil((y_max - y_min) / tile_size_y))

    cell_segmentation_dir = path_landscape_files + "/cell_segmentation"
    os.makedirs(cell_segmentation_dir, exist_ok=True)

    for i in range(n_tiles_x):
        if i % 2 == 0:
            print("row", i)

        for j in range(n_tiles_y):
            tile_x_min = x_min + i * tile_size_x
            tile_x_max = tile_x_min + tile_size_x
            tile_y_min = y_min + j * tile_size_y
            tile_y_max = tile_y_min + tile_size_y

            keep_cells = cells[
                (cells.center_x >= tile_x_min)
                & (cells.center_x < tile_x_max)
                & (cells.center_y >= tile_y_min)
                & (cells.center_y < tile_y_max)
            ].index.tolist()

            inst_geo = cells.loc[keep_cells, ["GEOMETRY"]]
            inst_geo["name"] = pd.Series(
                inst_geo.index.tolist(), index=inst_geo.index.tolist()
            )

            filename = f"{cell_segmentation_dir}/cell_tile_{i}_{j}.parquet"
            if inst_geo.shape[0] > 0:
                inst_geo[["GEOMETRY", "name"]].to_parquet(filename)

    # Process Meta Gene
    adata_cell = sc.read_10x_h5(
        f"{data_dir}/{sample}/segmented_outputs/filtered_feature_cell_matrix.h5"
    )
    list_genes = adata_cell.var.index.tolist()
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

    # Cell-by-gene (CBG)
    cbg_df = dega.pre.read_cbg_mtx(
        f"{data_dir}/{sample}/segmented_outputs/filtered_feature_cell_matrix",
        technology="Visium-HD",
    )
    cbg_df.index = (
        cbg_df.index.str.extract(r"cellid_0*(\d+)-")[0]
        .astype(int)
        .astype(str)
        .map(lambda x: f"c-{x}")
    )
    cbg_df.columns = cbg_df.columns.str.replace("/", "_", regex=False)
    cbg_df = make_column_names_unique_fast(cbg_df)

    list_ser = []
    clusters = def_clusters["cluster"].unique().tolist()
    for inst_cat in clusters:
        if inst_cat is not None:
            inst_cells = def_clusters[def_clusters["cluster"] == inst_cat].index.tolist()
            if set(inst_cells) & set(cbg_df.index):
                common_cells = list(set(inst_cells) & set(cbg_df.index))
                inst_ser = cbg_df.loc[common_cells].sum() / len(common_cells)
            else:
                genes = cbg_df.columns
                inst_ser = pd.Series(0.0, index=genes)

            inst_ser.name = inst_cat
            list_ser.append(inst_ser)

    df_sig = pd.concat(list_ser, axis=1)
    df_sig.columns = df_sig.columns.tolist()
    df_sig.index = df_sig.index.tolist()

    keep_genes = [
        x
        for x in df_sig.index.tolist()
        if "Unassigned" not in x and "NegControl" not in x and "DeprecatedCodeword" not in x
    ]
    df_sig = df_sig.loc[keep_genes, clusters]
    df_sig = df_sig.dropna(axis=1, how="all")
    df_sig = df_sig.loc[sorted(df_sig.index), sorted(df_sig.columns)]

    for col in df_sig.columns:
        if isinstance(df_sig[col].dtype, pd.SparseDtype):
            df_sig[col] = df_sig[col].sparse.to_dense()

    df_sig = df_sig[(df_sig != 0).any(axis=1)]
    df_sig = df_sig.loc[df_sig.std(axis=1) != 0]
    df_sig = df_sig.replace([np.inf, -np.inf], np.nan).dropna()
    df_sig.to_parquet(f"{path_landscape_files}/df_sig.parquet")

    dega.pre.make_meta_gene(cbg_df, path_landscape_files + "/meta_gene.parquet")
    dega.pre.save_cbg_gene_parquets(
        "Visium-HD", path_landscape_files, cbg_df, verbose=True
    )

    # Jittered transcripts
    tissue_positions = pd.read_parquet(
        f"{data_dir}/{sample}/binned_outputs/square_00{bin_size}um/spatial/tissue_positions.parquet"
    )
    spots = tissue_positions[tissue_positions["in_tissue"] == 1]
    spots.set_index("barcode", inplace=True)
    spots.drop(["array_row", "array_col"], axis=1, inplace=True)
    spots.rename(
        columns={
            "pxl_row_in_fullres": "y",
            "pxl_col_in_fullres": "x",
        },
        inplace=True,
    )

    gene_str_to_int = dega.pre.boundary_tile._get_name_mapping(
        path_landscape_files, layer="transcript"
    )

    sbg = dega.pre.read_cbg_mtx(
        f"{data_dir}/{sample}/binned_outputs/square_00{bin_size}um/filtered_feature_bc_matrix",
        technology="Visium-HD",
    )
    sbg = make_column_names_unique_fast(sbg)

    total_trx = sbg.sum(axis=0).sum()
    print(f"Total transcripts: {total_trx/1e6:.1f}M")

    rng = np.random.default_rng()
    transcript_tiles_dir = Path(path_landscape_files) / "transcript_tiles"
    transcript_tiles_dir.mkdir(parents=True, exist_ok=True)

    for i in range(n_tiles_x):
        if i % 10 == 0:
            print("row", i)

        for j in range(n_tiles_y):
            tile_x_min = tile_bounds["x_min"] + i * tile_size
            tile_x_max = tile_x_min + tile_size
            tile_y_min = tile_bounds["y_min"] + j * tile_size
            tile_y_max = tile_y_min + tile_size

            tile_spots = spots[
                (spots.x >= tile_x_min)
                & (spots.x < tile_x_max)
                & (spots.y >= tile_y_min)
                & (spots.y < tile_y_max)
            ]
            if tile_spots.empty:
                continue

            inst_spots = tile_spots.index.tolist()
            tile_sbg = sbg.loc[inst_spots]
            tile_sbg_coo = csr_matrix(tile_sbg.values)
            if tile_sbg_coo.nnz == 0:
                continue

            coo = csr_matrix(tile_sbg.values).tocoo()
            row = np.array([inst_spots[r] for r in coo.row])
            col = tile_sbg.columns.to_numpy()[coo.col]
            count = coo.data

            df = pd.DataFrame({"spot": row, "gene": col, "count": count})
            df = df[df["count"] > 0]
            df = df.loc[df.index.repeat(df["count"].astype(int))].reset_index(drop=True)

            df["x"] = df["spot"].map(tile_spots["x"])
            df["y"] = df["spot"].map(tile_spots["y"])
            df["name"] = df["gene"].map(gene_str_to_int).astype("int32")

            pl_df = pl.DataFrame(df[["name", "x", "y"]])
            jitter_radius = jitter / 2
            jitter_x = rng.uniform(-jitter_radius, jitter_radius, size=len(pl_df))
            jitter_y = rng.uniform(-jitter_radius, jitter_radius, size=len(pl_df))

            pl_df = pl_df.with_columns(
                [
                    (pl.col("x") + pl.Series(jitter_x)).round(2).alias("x"),
                    (pl.col("y") + pl.Series(jitter_y)).round(2).alias("y"),
                ]
            )

            df_out = pl_df.to_pandas()
            df_out["geometry"] = df_out[["x", "y"]].values.tolist()
            filename = transcript_tiles_dir / f"transcripts_tile_{i}_{j}.parquet"
            df_out[["name", "geometry"]].to_parquet(filename, index=False)

    # Save Landscape Parameters
    image_files_path = path_landscape_files + f"/pyramid_images/{image_tile_layer}_files"
    max_pyramid_zoom = dega.pre.get_max_zoom_level(image_files_path)

    landscape_parameters = {
        "technology": "Visium-HD",
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
    }
    landscape_parameters_path = Path(f"{path_landscape_files}/landscape_parameters.json")
    with landscape_parameters_path.open("w") as f:
        json.dump(landscape_parameters, f, indent=2)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Visium-HD-Celldega-LandscapeFiles-Preprocess"
    )
    parser.add_argument("--data_dir", type=str)
    parser.add_argument("--sample", type=str)
    parser.add_argument("--image_file_name", type=str)
    parser.add_argument("--path_landscape_files", type=str)
    parser.add_argument("--use_dummy_clusters", type=bool)
    parser.add_argument("--tile_size", type=int)
    parser.add_argument("--bin_size", type=int)
    parser.add_argument("--jitter", type=int)
    parser.add_argument("--image_scale", type=float)
    args = parser.parse_args()

    main(
        data_dir=args.data_dir,
        sample=args.sample,
        image_file_name=args.image_file_name,
        path_landscape_files=args.path_landscape_files,
        use_dummy_clusters=args.use_dummy_clusters,
        tile_size=args.tile_size,
        bin_size=args.bin_size,
        jitter=args.jitter,
        image_scale=args.image_scale,
    )