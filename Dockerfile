FROM python:3.11-slim-bookworm

# --- Environment setup ---
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# --- Install dependencies ---
RUN set -eux; \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        npm \
        build-essential \
        unzip \
        ca-certificates \
        curl \
        gnupg \
        xz-utils \
        bzip2 \
        tar \
        zlib1g-dev \
        libssl-dev \
        libcurl4-openssl-dev \
        libgl1-mesa-glx \
        libvips \
        libvips-tools \
        libvips-dev \
        pkg-config \
        gdal-bin \
        libgdal-dev \
        libgeos-dev \
        libspatialindex-dev \
        proj-bin \
        libproj-dev && \
    # --- Google Cloud SDK ---
    install -d -m 0755 /etc/apt/keyrings && \
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
      | gpg --dearmor -o /etc/apt/keyrings/google-cloud-sdk.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/google-cloud-sdk.gpg] http://packages.cloud.google.com/apt cloud-sdk main" \
      > /etc/apt/sources.list.d/google-cloud-sdk.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends google-cloud-sdk && \
    # --- AWS CLI v2 ---
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip" && \
    unzip /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/aws /tmp/awscliv2.zip && \
    # --- Cleanup ---
    apt-get clean && rm -rf /var/lib/apt/lists/*

# --- Verify installations ---
RUN gcloud --version && gsutil version -l && aws --version

# --- Python dependencies ---
# Celldega version. Empty (the default) installs the latest release from PyPI.
# Set it to pin a reproducible build, e.g. --build-arg CELLDEGA_VERSION=0.24.1
ARG CELLDEGA_VERSION=

# Docker caches the pip layer below, so an unchanged Dockerfile would reuse
# whatever celldega was latest when the image was FIRST built. To always pick up
# the newest release, ADD fetches celldega's PyPI metadata on every build: when
# a new release is published the file content changes, which invalidates the
# cache for every layer after it and forces pip to re-resolve.
ADD https://pypi.org/pypi/celldega/json /tmp/celldega_pypi.json

# Manual override: --build-arg CACHEBUST=$(date +%s) forces a reinstall regardless.
ARG CACHEBUST=0

# pyvips is needed by _convert_to_png / make_deepzoom_pyramid. It is optional in
# celldega (celldega.pre imports it as None if absent), so install it explicitly.
# The ~=2.2.2 bound mirrors celldega's own [pre] extra -- keep the two in sync.
# geopandas, matplotlib, numpy, pandas, polars, tifffile, scipy and shapely are
# already celldega runtime deps, so they are resolved with celldega's own pins
# (e.g. numpy>=2, shapely>=2.0,<2.2) rather than floating free.
RUN echo "cachebust=${CACHEBUST}" && \
    pip install --upgrade pip && \
    pip install --no-cache-dir \
      "celldega${CELLDEGA_VERSION:+==${CELLDEGA_VERSION}}" \
      "pyvips~=2.2.2"

# --- Verify celldega ---
# celldega.pre swallows a failed pyvips import and sets pyvips = None, which would
# otherwise surface much later as "'NoneType' object has no attribute 'Image'" at
# the first image step. Fail the build here instead.
RUN python -c "import celldega, celldega.pre as pre, pyvips; \
    assert pre.pyvips is not None, 'pyvips did not load (check libvips and the pyvips pin)'; \
    print('celldega', celldega.__version__, '| pyvips', pyvips.__version__)"

# When no version is pinned, fail the build if the installed celldega is not the
# newest release on PyPI (guards against a stale cached layer).
RUN if [ -z "${CELLDEGA_VERSION}" ]; then \
      python -c "import json, celldega; latest = json.load(open('/tmp/celldega_pypi.json'))['info']['version']; assert celldega.__version__ == latest, f'celldega {celldega.__version__} != latest on PyPI {latest}'; print('celldega is latest:', latest)"; \
    fi

# --- Copy Python scripts ---
WORKDIR /opt
COPY python_scripts/*.py /opt/
RUN chmod +x /opt/*.py

# --- Entry point ---
ENTRYPOINT ["/bin/bash"]