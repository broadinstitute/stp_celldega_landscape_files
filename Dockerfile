FROM python:3.10-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
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
        # geospatial deps
        gdal-bin \
        libgdal-dev \
        libgeos-dev \
        libspatialindex-dev \
        proj-bin \
        libproj-dev; \
    \
    # Google Cloud SDK (gsutil)
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
      | gpg --dearmor -o /etc/apt/keyrings/google-cloud-sdk.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/google-cloud-sdk.gpg] http://packages.cloud.google.com/apt cloud-sdk main" \
      > /etc/apt/sources.list.d/google-cloud-sdk.list; \
    apt-get update; \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends google-cloud-sdk; \
    \
    # AWS CLI v2
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"; \
    unzip /tmp/awscliv2.zip -d /tmp; \
    /tmp/aws/install; \
    rm -rf /tmp/aws /tmp/awscliv2.zip; \
    \
    rm -rf /var/lib/apt/lists/*

# sanity check
RUN gcloud --version && gcloud info && gcloud config list && gsutil version -l && aws --version

# Python deps
RUN pip install --upgrade pip && \
    # install celldega prerelease specifically
    pip install --no-cache-dir --pre celldega && \
    # install rest as stable
    pip install --no-cache-dir \
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

# Copy Python scripts into /opt
COPY Visium_HD_Landscape_Pre_process.py /opt/Visium_HD_Landscape_Pre_process.py

# Make specific scripts executable
RUN chmod +x /opt/Visium_HD_Landscape_Pre_process.py

ENTRYPOINT ["/bin/bash"]
CMD ["-c", "echo \"This is a test.\" | wc -"]