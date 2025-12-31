#!/bin/bash

BASE_JSON='{
  "source": "huggingface",
  "huggingface_repo_id": "Qwen/Qwen3-0.6B",
  "huggingface_filename": null,
  "model_scope_model_id": null,
  "model_scope_file_path": null,
  "local_path": null,
  "name": "qwen3-0.6b",
  "description": null,
  "meta": {},
  "replicas": REPLICA_PLACEHOLDER,
  "ready_replicas": 1,
  "categories": ["llm"],
  "placement_strategy": "spread",
  "cpu_offloading": true,
  "distributed_inference_across_workers": true,
  "worker_selector": {},
  "gpu_selector": null,
  "backend": "tail-custom",
  "backend_version": "v1",
  "backend_parameters": [],
  "image_name": null,
  "run_command": null,
  "env": null,
  "restart_on_error": true,
  "distributable": false,
  "extended_kv_cache": {
    "enabled": false,
    "ram_ratio": 1.2,
    "ram_size": null,
    "chunk_size": null
  },
  "speculative_config": {
    "enabled": false,
    "algorithm": null,
    "draft_model": null,
    "num_draft_tokens": null,
    "ngram_min_match_length": null,
    "ngram_max_match_length": null
  },
  "generic_proxy": false,
  "cluster_id": 1,
  "access_policy": "authed",
  "id": 1,
  "created_at": "2025-12-25T03:06:32.663352Z",
  "updated_at": "2025-12-25T04:54:58.289002Z"
}'

URL="http://localhost/v2/models/1"
HEADERS=(
  -H 'accept: application/json'
  -H 'Content-Type: application/json'
)

send_replicas() {
  local replicas=$1
  local json_body="${BASE_JSON/REPLICA_PLACEHOLDER/$replicas}"
  curl -X PUT "$URL" "${HEADERS[@]}" -d "$json_body" --silent --show-error
}

echo "🔄 Starting continuous full-body toggle: replicas=0 → replicas=1 every 1 second."
echo "   (Full model config is sent each time. Press Ctrl+C to stop.)"
echo

while true; do
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⛔ Sending replicas=0 (stop)..."
  send_replicas 0
  sleep 0.1

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ Sending replicas=1 (start)..."
  send_replicas 1

  sleep 0.1
done
