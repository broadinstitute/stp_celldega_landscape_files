FROM python:3.10-bookworm

# System deps (mirroring your style) + libvips for celldega workflows
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl \
    tar \
    bzip2 \
    xz-utils \
    gnupg \
    ca-certificates \
    apt-transport-https \
    libssl-dev \
    libcurl4-openssl-dev \
    zlib1g-dev \
    libgl1-mesa-glx \
    libvips \
    libvips-tools \
    libvips-dev \
    && apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Add Google Cloud SDK apt repo (signed-by keyring, like your example)
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] http://packages.cloud.google.com/apt cloud-sdk main" \
      | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list && \
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
      | apt-key --keyring /usr/share/keyrings/cloud.google.gpg add -

# Install Google Cloud SDK (includes gcloud and gsutil) with a retry
RUN apt-get update && \
    apt-get install -y --no-install-recommends google-cloud-sdk || \
      (sleep 30 && apt-get install -y --no-install-recommends google-cloud-sdk) && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Quick sanity checks (optional but mirrors your inspiration)
RUN gcloud --version && \
    gcloud info && \
    gcloud config list && \
    gsutil version -l

# Python deps
RUN pip install --upgrade pip && \
    pip install celldega

WORKDIR /usr/src/app

CMD ["/bin/bash"]
