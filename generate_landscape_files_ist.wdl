version 1.0

task generate_landscape_files {

  input {
    String sample
    String data_dir
    String bucket_path_landscape_files
    Int tile_size
    String celldega_docker_image
    String image_tile_layer
  }

  command <<<
    #!/bin/bash
    set -euo pipefail
    IFS=$'\n\t'

    SAMPLE="~{sample}"
    USER_DATA_DIR="~{data_dir}"
    USER_OUTPUT_DIR="~{bucket_path_landscape_files}"

    DATA_ROOT="${PWD}"
    OUTDIR="${DATA_ROOT}/landscape_files_temp"
    IN_DIR="${DATA_ROOT}/${SAMPLE}"

    mkdir -p "${IN_DIR}" "${OUTDIR}"

    echo "Checking data_dir source: ${USER_DATA_DIR}"

    if [[ "${USER_DATA_DIR}" == s3://* ]]; then
      echo "Detected AWS S3 path, using aws s3 sync..."
      aws s3 sync "${USER_DATA_DIR%/}/${SAMPLE}" "${IN_DIR}/" --exclude "._*" --exclude ".DS_Store"

    elif [[ "${USER_DATA_DIR}" == gs://* ]]; then
      echo "Detected Google Cloud Storage path, using gcloud storage rsync..."
      gcloud storage rsync -r "${USER_DATA_DIR%/}/${SAMPLE}" "${IN_DIR}/"

    else
      echo "ERROR: data_dir must start with s3:// or gs://"
      exit 1
    fi

    if [[ -z "$(find "${IN_DIR}" -type f -print -quit)" ]]; then
      echo "ERROR: No files found under ${USER_DATA_DIR}/${SAMPLE}." >&2
      exit 2
    fi

    export SAMPLE DATA_ROOT OUTDIR

    echo "Running celldega $(python3 -c 'import celldega; print(celldega.__version__)') (image: ~{celldega_docker_image})"
    python3 <<'PY'
import os
import celldega as dega
dega.pre.main(
    sample=os.environ["SAMPLE"],
    data_root_dir=os.environ["DATA_ROOT"],
    tile_size=~{tile_size},
    image_tile_layer="~{image_tile_layer}",
    path_dega_files=os.environ["OUTDIR"],
    use_int_index=True,
)
PY

    # Precompute the Clustergram marker store (markers.zarr) so the visualization
    # notebook only has to read it from disk. Runs in its own python process and
    # a failure here does not skip the sync below, so the (slow) landscape files
    # are never lost; the task is still failed at the end.
    ZARR_STATUS=0
    python3 <<'PY' || ZARR_STATUS=$?
import os
import shutil
import warnings
from concurrent.futures import ThreadPoolExecutor
from importlib.metadata import version as _pkg_version
from pathlib import Path

import anndata as ad
import celldega as dega
import numpy as np
import pandas as pd
import scanpy as sc
import scipy.sparse as sp

assert int(_pkg_version("zarr").split(".")[0]) >= 3, "zarr >= 3 is required"

MARKER_LEVELS = [1, 2, 3, 5, 10, 25, 50, 75]   # top markers per Leiden cluster, one precomputed Clustergram view each
N_THREADS = min(32, os.cpu_count() or 1)       # parallel reads of cbg/<gene>.parquet

region_dir = Path(os.environ["OUTDIR"])
out_path = region_dir / "markers.zarr"

meta_cluster = pd.read_parquet(region_dir / "cell_clusters" / "meta_cluster.parquet")
df_sig = pd.read_parquet(region_dir / "df_sig.parquet")
cell_cluster = pd.read_parquet(region_dir / "cell_clusters" / "cluster.parquet")["cluster"].astype(str)
clusters = sorted(df_sig.columns, key=int)       # Leiden cluster labels
genes = df_sig.index.tolist()

# Cell x gene counts from the per-gene cbg files (sparse: cell position -> count)
def load_gene(gene):
    counts = pd.read_parquet(region_dir / "cbg" / f"{gene}.parquet").iloc[:, 0]
    return counts.index.to_numpy(), counts.to_numpy(dtype="float32")

with ThreadPoolExecutor(N_THREADS) as pool:
    per_gene = list(pool.map(load_gene, genes))

indptr = np.cumsum([0] + [len(rows) for rows, _ in per_gene])
counts = sp.csc_matrix(
    (np.concatenate([v for _, v in per_gene]), np.concatenate([r for r, _ in per_gene]), indptr),
    shape=(len(cell_cluster), len(genes)),
).tocsr()
cells = ad.AnnData(
    counts,
    obs=pd.DataFrame({"leiden": pd.Categorical(cell_cluster.values, categories=clusters)}, index=cell_cluster.index),
    var=pd.DataFrame(index=genes),
)
cells.uns["leiden_colors"] = meta_cluster.loc[clusters, "color"].tolist()    # same colors as the Landscape
print(f"{cells.n_obs:,} cells x {cells.n_vars:,} genes; {int(cells.obs['leiden'].isna().sum()):,} cells without a cluster are ignored")

# Marker ranking on log-normalized counts (each cluster vs the rest)
sc.pp.normalize_total(cells)
sc.pp.log1p(cells)
with warnings.catch_warnings():
    warnings.simplefilter("ignore")
    sc.tl.rank_genes_groups(cells, groupby="leiden", method="t-test", use_raw=False, n_genes=cells.n_vars)
# Color each gene by the cluster where its marker score is highest
markers = sc.get.rank_genes_groups_df(cells, group=None)
best_group = markers.sort_values("scores", ascending=False).drop_duplicates("names").set_index("names")["group"]
cells.var["leiden_marker"] = pd.Categorical(best_group.reindex(cells.var_names), categories=clusters)

# Celldega aggregates the cells into cluster signatures (mean expression) and the
# fraction of cells expressing each gene (dot size), reusing the ranks computed above.
mat = dega.clust.Matrix(cells, groupby="leiden", col_attr=["leiden"], row_attr=["leiden_marker"])
mat.norm("row", by="zscore")
mat.cluster(view="rank_genes_groups", levels=MARKER_LEVELS)

if out_path.exists():
    shutil.rmtree(out_path)
mat.write_zarr(out_path)

for view in mat.views:
    print(f"  {view['level']:>3} markers/cluster -> {view['n_rows']} genes")
print(f"wrote {out_path}")

# Check that the store opens
dega.clust.Matrix.read_zarr(out_path)
PY

    echo "Syncing outputs back to bucket..."

    if [[ "${USER_OUTPUT_DIR}" == s3://* ]]; then
      aws s3 sync "${OUTDIR}/" "${USER_OUTPUT_DIR%/}/${SAMPLE}/" --no-progress
    elif [[ "${USER_OUTPUT_DIR}" == gs://* ]]; then
      gcloud storage rsync -r "${OUTDIR}/" "${USER_OUTPUT_DIR%/}/${SAMPLE}/"
    else
      echo "ERROR: bucket_path_landscape_files must start with s3:// or gs://"
      exit 1
    fi

    if [[ "${ZARR_STATUS}" -ne 0 ]]; then
      echo "ERROR: markers.zarr generation failed (exit ${ZARR_STATUS}); the other landscape files were synced." >&2
      exit "${ZARR_STATUS}"
    fi

    echo "Done."
  >>>

  runtime {
    docker: celldega_docker_image
    memory: "200 GB"
    disks: "local-disk 200 HDD"
    preemptible: 0
  }
}
