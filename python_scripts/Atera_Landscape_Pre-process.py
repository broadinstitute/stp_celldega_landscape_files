"""Atera (10x Atera bundle) -> Celldega DegaFiles.

Runs celldega's pre-processing for one Atera region, with two Atera-specific safeguards:

1. patch_zarr_short_object_chunks(): the Atera bundle stores the last chunk of some string
   arrays (e.g. obs/barcode in cell_feature_matrix.zarr.zip) without padding it to the declared
   chunk size (575154 values in a 1,000,000 chunk). zarr 3 refuses to read that
   ("cannot reshape array of size 575154 into shape (1000000,)"), so such chunks are padded
   in memory when read. Nothing is written back to the bundle.
2. verify_atera_barcodes(): before the long run, reads the barcodes a second way (straight from
   the zip with numcodecs, bypassing zarr) and fails in seconds unless both reads agree.

The bundle is expected at <data_dir>/<sample>/ and must contain experiment.spatial,
cells.zarr.zip, transcripts.zarr.zip, cell_feature_matrix.zarr.zip and morphology_2d/ch*.ome.tif.

Usage:
    python3 /opt/Atera_Landscape_Pre-process.py \\
        --data_dir /path/holding/the/sample/folder --sample <region> \\
        --path_landscape_files /path/for/the/DegaFiles --tile_size 250
"""

import argparse
import os


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


def verify_atera_barcodes(bundle):
    """Check that the patched zarr read of obs/barcode returns exactly the stored values.

    Reads the barcodes twice -- through zarr (with the patch) and straight from the zip with
    numcodecs -- and requires identical values, the declared length, no empty strings, and that
    every barcode is a cell in cells.zarr.zip. Raises (failing the job in seconds) otherwise.
    """
    import json
    import zipfile
    from pathlib import Path

    import numcodecs
    import numpy as np
    import zarr

    bundle = Path(bundle)
    cbg_path = bundle / "cell_feature_matrix.zarr.zip"

    # 1) the patched zarr read
    root = zarr.open_group(store=zarr.storage.ZipStore(str(cbg_path), mode="r"), mode="r")
    via_zarr = np.asarray(root["obs"]["barcode"][:], dtype=object).astype(str)
    n_rows = int(tuple(root["X"].attrs["shape"])[0])

    # 2) an independent read: decode the raw stored chunks with numcodecs, bypassing zarr
    with zipfile.ZipFile(cbg_path) as zf:
        meta_name = next(n for n in zf.namelist() if n.endswith("obs/barcode/.zarray"))
        prefix = meta_name[: -len(".zarray")]
        meta = json.loads(zf.read(meta_name))
        if meta["dtype"] != "|O":
            raise RuntimeError(f"obs/barcode has dtype {meta['dtype']}, not a string-object array; cannot verify")
        length, chunk_len = meta["shape"][0], meta["chunks"][0]
        compressor = numcodecs.get_codec(meta["compressor"]) if meta.get("compressor") else None
        filters = [numcodecs.get_codec(f) for f in (meta.get("filters") or [])]
        parts = []
        n_chunks = -(-length // chunk_len)
        for i in range(n_chunks):
            data = zf.read(f"{prefix}{i}")
            if compressor is not None:
                data = compressor.decode(data)
            for f in reversed(filters):
                data = f.decode(data)
            values = np.asarray(data, dtype=object).reshape(-1)
            expected = min(chunk_len, length - i * chunk_len)    # real values in this chunk
            if len(values) < expected or (i < n_chunks - 1 and len(values) != chunk_len):
                raise RuntimeError(f"obs/barcode chunk {i} holds {len(values)} values, expected {expected}")
            parts.append(values[:expected])
        independent = np.concatenate(parts).astype(str)

    problems = []
    if len(via_zarr) != length:
        problems.append(f"zarr read returned {len(via_zarr)} barcodes, the array declares {length}")
    if length != n_rows:
        problems.append(f"{length} barcodes but the matrix has {n_rows} rows")
    if not np.array_equal(via_zarr, independent):
        problems.append("the patched zarr read differs from the independent numcodecs read")
    if (via_zarr == "").any():
        problems.append("empty barcodes in the result (padding leaked)")

    # 3) cross-check against a second array that never needed the patch: the cell ids in cells.zarr.zip
    try:
        from celldega.pre.atera import _encode_cell_ids
    except ImportError:
        _encode_cell_ids = None
        print("note: could not import celldega's cell-id encoder; skipping the cells.zarr.zip cross-check")
    if _encode_cell_ids is not None:
        cells = zarr.open_group(store=zarr.storage.ZipStore(str(bundle / "cells.zarr.zip"), mode="r"), mode="r")
        cell_ids = _encode_cell_ids(cells["cell_id"][:])
        in_cells = np.isin(via_zarr, cell_ids)
        if not in_cells.all():
            problems.append(f"{int((~in_cells).sum())} barcodes are not cell ids in cells.zarr.zip")
        print(f"verify: {len(via_zarr):,} barcodes; {int(in_cells.sum()):,} found in cells.zarr.zip ({len(cell_ids):,} cells)")

    if problems:
        raise RuntimeError("Atera barcode check FAILED: " + "; ".join(problems))
    print(f"verify: OK -- patched zarr read == independent read for all {len(via_zarr):,} barcodes "
          f"(chunk size {chunk_len:,}, {n_chunks} chunk(s))")

def main(sample, data_dir, path_landscape_files, tile_size=250, image_tile_layer="all",
         use_int_index=True, skip_barcode_check=False):
    """Pre-process one Atera region into DegaFiles under path_landscape_files."""
    import celldega as dega

    print(f"celldega {dega.__version__}: Atera region {sample}")
    patch_zarr_short_object_chunks()
    print("Applied the zarr short string-chunk patch")
    if skip_barcode_check:
        print("Skipping the barcode check (--skip_barcode_check)")
    else:
        # Fails in seconds, before the long run, unless the patched read returns exactly the stored barcodes
        verify_atera_barcodes(os.path.join(data_dir, sample))

    dega.pre.main(
        sample=sample,
        data_root_dir=data_dir,
        tile_size=tile_size,
        image_tile_layer=image_tile_layer,
        path_dega_files=path_landscape_files,
        use_int_index=use_int_index,
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Atera-Celldega-LandscapeFiles-Preprocess")
    parser.add_argument("--data_dir", type=str, required=True, help="folder that contains the <sample>/ bundle folder")
    parser.add_argument("--sample", type=str, required=True, help="region folder name")
    parser.add_argument("--path_landscape_files", type=str, required=True, help="output folder for the DegaFiles")
    parser.add_argument("--tile_size", type=int, default=250)
    parser.add_argument("--image_tile_layer", type=str, default="all", choices=["all", "dapi"])
    parser.add_argument("--skip_barcode_check", action="store_true", help="skip the patched-read verification")
    args = parser.parse_args()

    main(
        sample=args.sample,
        data_dir=args.data_dir,
        path_landscape_files=args.path_landscape_files,
        tile_size=args.tile_size,
        image_tile_layer=args.image_tile_layer,
        skip_barcode_check=args.skip_barcode_check,
    )
