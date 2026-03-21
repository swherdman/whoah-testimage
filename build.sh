#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "=== Building Docker builder image ==="
docker build -t whoah-testimage-builder -f Dockerfile.builder .

echo "=== Building image ==="
docker run --rm --privileged \
    -v "$(pwd)/output:/output" \
    -v "$(pwd)/rootfs:/rootfs:ro" \
    -v "$(pwd)/scripts:/scripts:ro" \
    whoah-testimage-builder /scripts/build-image.sh

echo ""
echo "=== Build complete ==="
ls -lh output/whoah-testimage.raw
