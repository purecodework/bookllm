#!/usr/bin/env bash
set -euo pipefail

# Push BookLLM images to Docker Hub with a consistent namespace:
#   <DOCKERHUB_USER>/bookllm-frontend
#   <DOCKERHUB_USER>/bookllm-backend
#   <DOCKERHUB_USER>/bookllm-ocr
#
# Usage:
#   DOCKERHUB_USER=yourname TAG=0.1.0 ./scripts/push-dockerhub.sh

DOCKERHUB_USER="${DOCKERHUB_USER:-}"
TAG="${TAG:-0.1.0}"

if [[ -z "${DOCKERHUB_USER}" ]]; then
  echo "ERROR: DOCKERHUB_USER is required."
  echo "Example: DOCKERHUB_USER=yourname TAG=0.1.0 ./scripts/push-dockerhub.sh"
  exit 1
fi

echo "==> Building release images"
docker compose build frontend backend ocr-service

echo "==> Tagging images"
docker tag bookllm-frontend:latest "${DOCKERHUB_USER}/bookllm-frontend:${TAG}"
docker tag bookllm-frontend:latest "${DOCKERHUB_USER}/bookllm-frontend:latest"

docker tag bookllm-backend:latest "${DOCKERHUB_USER}/bookllm-backend:${TAG}"
docker tag bookllm-backend:latest "${DOCKERHUB_USER}/bookllm-backend:latest"

docker tag bookllm-ocr:latest "${DOCKERHUB_USER}/bookllm-ocr:${TAG}"
docker tag bookllm-ocr:latest "${DOCKERHUB_USER}/bookllm-ocr:latest"

echo "==> Pushing images"
docker push "${DOCKERHUB_USER}/bookllm-frontend:${TAG}"
docker push "${DOCKERHUB_USER}/bookllm-frontend:latest"

docker push "${DOCKERHUB_USER}/bookllm-backend:${TAG}"
docker push "${DOCKERHUB_USER}/bookllm-backend:latest"

docker push "${DOCKERHUB_USER}/bookllm-ocr:${TAG}"
docker push "${DOCKERHUB_USER}/bookllm-ocr:latest"

echo "==> Done"
echo "${DOCKERHUB_USER}/bookllm-frontend:${TAG}"
echo "${DOCKERHUB_USER}/bookllm-backend:${TAG}"
echo "${DOCKERHUB_USER}/bookllm-ocr:${TAG}"
