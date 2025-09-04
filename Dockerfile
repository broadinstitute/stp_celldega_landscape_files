FROM python:3.10-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
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
        **build-essential \
        pkg-config**; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
      | gpg --dearmor -o /etc/apt/keyrings/google-cloud-sdk.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/google-cloud-sdk.gpg] http://packages.cloud.google.com/apt cloud-sdk main" \
      > /etc/apt/sources.list.d/google-cloud-sdk.list; \
    apt-get update; \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends google-cloud-sdk; \
    rm -rf /var/lib/apt/lists/*

RUN gcloud --version && gcloud info && gcloud config list && gsutil version -l

RUN pip install --upgrade pip && \
    pip install --no-cache-dir pyvips celldega

WORKDIR /usr/src/app
CMD ["/bin/bash"]