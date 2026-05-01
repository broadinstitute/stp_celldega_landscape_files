FROM python:3.10-slim-bookworm

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
ARG CELLDEGA_REF=main

RUN pip install --upgrade pip && \
    pip install --no-cache-dir \
      "git+https://github.com/broadinstitute/celldega.git@${CELLDEGA_REF}" \
      pyvips \
      fiona \
      geopandas \
      matplotlib \
      numpy \
      pandas \
      polars \
      scanpy \
      tifffile \
      scipy \
      shapely

# --- Copy Python scripts ---
WORKDIR /opt
COPY python_scripts/*.py /opt/
RUN chmod +x /opt/*.py

# --- Entry point ---
ENTRYPOINT ["/bin/bash"]