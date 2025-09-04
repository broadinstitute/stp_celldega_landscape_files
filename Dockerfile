FROM python:3.10

RUN apt-get update && \
    apt-get install -y \
    libvips libvips-tools libvips-dev \
    && apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN pip install --upgrade pip && \
    pip install celldega

WORKDIR /usr/src/app

CMD ["/bin/bash"]