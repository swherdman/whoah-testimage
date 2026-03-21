#!/bin/bash
set -e

PROFILE="${OXIDE_PROFILE:-recovery3}"
PROJECT="${OXIDE_PROJECT:-whoah-test}"
INSTANCE_NAME="whoah-testimage"
IMAGE_PATH="output/whoah-testimage.raw"

cd "$(dirname "$0")"

if [ ! -f "$IMAGE_PATH" ]; then
    echo "Error: $IMAGE_PATH not found. Run ./build.sh first."
    exit 1
fi

echo "=== Uploading image to Oxide ==="
oxide --profile "$PROFILE" disk import \
    --project "$PROJECT" \
    --path "$IMAGE_PATH" \
    --disk "${INSTANCE_NAME}-boot" \
    --disk-block-size 512 \
    --snapshot "${INSTANCE_NAME}-snapshot" \
    --image "${INSTANCE_NAME}-image" \
    --image-description "It is pitch black." \
    --image-os alpine \
    --image-version "3.21"

echo "=== Creating instance ==="
oxide --profile "$PROFILE" instance create \
    --project "$PROJECT" \
    --json-body <(cat << EOF
{
    "description": "It is pitch black.",
    "hostname": "$INSTANCE_NAME",
    "memory": 1073741824,
    "name": "$INSTANCE_NAME",
    "ncpus": 1,
    "disks": [{"type": "attach", "name": "${INSTANCE_NAME}-boot"}],
    "start": true
}
EOF
)

echo ""
echo "=== Instance created. Connect via: ==="
echo "oxide --profile $PROFILE instance serial console --project $PROJECT --instance $INSTANCE_NAME"
