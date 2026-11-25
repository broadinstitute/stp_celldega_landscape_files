version 1.0

task generate_landscape_files {

  input {
    String sample
    String data_dir
    String bucket_path_landscape_files
    Int tile_size
    String celldega_docker_image
    String image_tile_layer
    # "Xenium", "MERSCOPE" or "Atera". Atera bundles are detected by celldega
    # itself (experiment.spatial); here it only enables the input check below.
    String technology = "Xenium"
    Int disk_gb = 200
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

    # Atera bundles also hold large files celldega never reads (3D morphology,
    # binned transcripts, the CSC matrix, diffexp output); skip them to save
    # download time and local disk.
    AWS_EXTRA_EXCLUDES=()
    GCS_EXTRA_EXCLUDES=()
    if [[ "~{technology}" == "Atera" ]]; then
      AWS_EXTRA_EXCLUDES=(--exclude "morphology_3d/*" --exclude "diffexp_genes/*" --exclude "binned_transcripts.zarr.zip" --exclude "csc_cell_feature_matrix.zarr.zip")
      GCS_EXTRA_EXCLUDES=(--exclude "^(morphology_3d/|diffexp_genes/|binned_transcripts\.zarr\.zip$|csc_cell_feature_matrix\.zarr\.zip$)")
    fi

    echo "Checking data_dir source: ${USER_DATA_DIR}"

    if [[ "${USER_DATA_DIR}" == s3://* ]]; then
      echo "Detected AWS S3 path, using aws s3 sync..."
      aws s3 sync "${USER_DATA_DIR%/}/${SAMPLE}" "${IN_DIR}/" --exclude "._*" --exclude ".DS_Store" ${AWS_EXTRA_EXCLUDES[@]+"${AWS_EXTRA_EXCLUDES[@]}"}

    elif [[ "${USER_DATA_DIR}" == gs://* ]]; then
      echo "Detected Google Cloud Storage path, using gcloud storage rsync..."
      gcloud storage rsync -r ${GCS_EXTRA_EXCLUDES[@]+"${GCS_EXTRA_EXCLUDES[@]}"} "${USER_DATA_DIR%/}/${SAMPLE}" "${IN_DIR}/"

    else
      echo "ERROR: data_dir must start with s3:// or gs://"
      exit 1
    fi

    if [[ -z "$(find "${IN_DIR}" -type f -print -quit)" ]]; then
      echo "ERROR: No files found under ${USER_DATA_DIR}/${SAMPLE}." >&2
      exit 2
    fi

    # A 10x Atera bundle is what celldega's Xenium pipeline reads through its
    # Atera readers; fail early (before the long run) if the bundle is incomplete.
    if [[ "~{technology}" == "Atera" ]]; then
      echo "Checking Atera bundle in ${IN_DIR}..."
      ATERA_MISSING=()
      for f in experiment.spatial cells.zarr.zip transcripts.zarr.zip cell_feature_matrix.zarr.zip; do
        [[ -e "${IN_DIR}/${f}" ]] || ATERA_MISSING+=("${f}")
      done
      # celldega reads morphology_2d/ch*.ome.tif (ch0000 = DAPI)
      if [[ -z "$(find "${IN_DIR}/morphology_2d" -maxdepth 1 -name 'ch*.ome.tif' -print -quit 2>/dev/null)" ]]; then
        ATERA_MISSING+=("morphology_2d/ch*.ome.tif")
      fi
      if [[ "${#ATERA_MISSING[@]}" -gt 0 ]]; then
        echo "ERROR: Atera bundle ${USER_DATA_DIR%/}/${SAMPLE} is missing: ${ATERA_MISSING[*]}" >&2
        exit 2
      fi
    fi

    export SAMPLE DATA_ROOT OUTDIR

    echo "Running celldega $(python3 -c 'import celldega; print(celldega.__version__)') (image: ~{celldega_docker_image})"
    python3 <<'PY'
import os
import celldega as dega

# Atera bundles store the last chunk of some string arrays (e.g. obs/barcode in
# cell_feature_matrix.zarr.zip) without padding it to the declared chunk size, which
# zarr 3 refuses to read ("cannot reshape array of size 575154 into shape (1000000,)").
# Retry just those chunks with padding; everything else is read as before.
def patch_zarr_short_object_chunks():
    """Let zarr 3 read zarr v2 string chunks that are shorter than the declared chunk shape.

    The Atera bundles store the last chunk of some string arrays (e.g. obs/barcode) with only the
    real values, not padded to the chunk size (575154 values for a 1,000,000 chunk), and zarr 3
    refuses to reshape them. Retry such a chunk with padding. Chunks that already decode fine,
    and non-string arrays, are untouched.
    """
    import numpy as np
    from numcodecs.compat import ensure_ndarray_like
    from zarr.codecs import _v2
    from zarr.registry import get_ndbuffer_class

    cls = _v2.V2Codec
    if getattr(cls, "_short_chunk_patch", False):
        return

    def decode_padded(codec, chunk_bytes, chunk_spec):
        data = chunk_bytes.as_array_like()
        chunk = codec.compressor.decode(data) if codec.compressor else data
        for f in reversed(codec.filters or ()):
            chunk = f.decode(chunk)
        chunk = ensure_ndarray_like(chunk)
        if chunk.dtype != object:
            raise ValueError("cannot reshape short non-string chunk")
        chunk = chunk.reshape(-1, order="A")
        expected = int(np.prod(chunk_spec.shape))
        if chunk.size > expected:
            raise ValueError(f"cannot reshape array of size {chunk.size} into shape {chunk_spec.shape}")
        fill = getattr(chunk_spec, "fill_value", None)
        padded = np.full(expected, "" if fill is None else fill, dtype=object)
        padded[: chunk.size] = chunk
        padded = padded.reshape(chunk_spec.shape, order=chunk_spec.order)
        return get_ndbuffer_class().from_ndarray_like(padded)

    original_single = cls._decode_single

    async def _decode_single(self, chunk_bytes, chunk_spec):
        try:
            return await original_single(self, chunk_bytes, chunk_spec)
        except ValueError as exc:
            if "cannot reshape" not in str(exc):
                raise
            return decode_padded(self, chunk_bytes, chunk_spec)

    cls._decode_single = _decode_single

    original_sync = getattr(cls, "_decode_sync", None)
    if original_sync is not None:   # newer zarr 3 versions decode through a sync method

        def _decode_sync(self, chunk_bytes, chunk_spec):
            try:
                return original_sync(self, chunk_bytes, chunk_spec)
            except ValueError as exc:
                if "cannot reshape" not in str(exc):
                    raise
                return decode_padded(self, chunk_bytes, chunk_spec)

        cls._decode_sync = _decode_sync

    cls._short_chunk_patch = True

if "~{technology}" == "Atera":
    patch_zarr_short_object_chunks()
    print("Applied the zarr short string-chunk patch for Atera")

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
def _cluster_key(label):
    # numeric labels sort numerically (2 before 10); anything else sorts by name
    s = str(label)
    return (0, int(s), s) if s.lstrip("-").isdigit() else (1, 0, s)

clusters = sorted(df_sig.columns, key=_cluster_key)   # Leiden cluster labels
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
    disks: "local-disk ~{disk_gb} HDD"
    preemptible: 0
  }
}
