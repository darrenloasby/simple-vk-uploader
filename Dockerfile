# Simplified VK Video Uploader with WireGuard Rotation
FROM alpine:3.19
# RUN apk update && apk search --no-cache fswatch
# Install system dependencies
RUN apk add --no-cache \
    tzdata \
    make \
    gcc \
    musl-dev \
    linux-headers \
    python3 \
    python3-dev \
    py3-pip \
    wireguard-tools \
    iptables \
    iproute2 \
    bind-tools \
    curl \
    bash \
    sudo \
    && rm -rf /var/cache/apk/*

# Allow passwordless sudo for WireGuard operations
RUN echo 'appuser ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers

# Create app user
RUN addgroup -g 1000 appuser && \
    adduser -D -u 1000 -G appuser appuser

# Set up application directory
WORKDIR /app
RUN mkdir -p /app/{wireguard,logs} && \
    chown -R appuser:appuser /app

# Create virtual environment as root (before switching to appuser)
RUN python3 -m venv /app/venv && \
    chown -R appuser:appuser /app/venv

# Copy requirements and install dependencies in venv
COPY requirements.txt /app/
RUN /app/venv/bin/pip install --no-cache-dir --upgrade pip && \
    /app/venv/bin/pip install --no-cache-dir -r requirements.txt

# Copy application files
COPY uploader.py /app/
COPY run.sh /app/
RUN chmod +x /app/run.sh

# Set proper ownership
RUN chown -R appuser:appuser /app

# Environment variables
ENV PYTHONUNBUFFERED=1 \
    LOG_LEVEL=INFO \
    PATH="/app/venv/bin:$PATH" \
    VIRTUAL_ENV=/app/venv

# Switch to non-root user
USER appuser

# Entry point
ENTRYPOINT ["/app/run.sh"]