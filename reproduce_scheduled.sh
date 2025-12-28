#!/bin/bash

echo "Install docker..."

# Add Docker's official GPG key:
sudo apt update
sudo apt install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update

sudo apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y

echo "Install GPUStack..."

sudo docker run -d --name gpustack \
    --restart unless-stopped \
    --network host \
    --volume /var/run/docker.sock:/var/run/docker.sock \
    --volume gpustack-data:/var/lib/gpustack \
    -e GPUSTACK_DEBUG=true \
    -e GPUSTACK_DISABLE_UPDATE_CHECK=true \
    -e GPUSTACK_ENABLE_WORKER=true \
    -e GPUSTACK_BOOTSTRAP_PASSWORD=123456 \
    gpustack/gpustack:main

echo "Add debugging..."

sleep 20
curl -O https://raw.githubusercontent.com/gitlawr/gpustack/debug-scheduled/gpustack/server/bus.py
docker cp bus.py gpustack:/usr/local/lib/python3.11/dist-packages/gpustack/server/bus.py
docker restart gpustack

echo "Waiting for GPUStack to become ready..."

timeout=60
count=0
while [ $count -lt $timeout ]; do
  if curl -sf http://localhost/healthz > /dev/null; then
    echo "✅ GPUStack is ready!"
    break
  fi
  echo "⏳ GPUStack not ready yet, retrying in 2 seconds... ($((count+1))/$timeout)"
  sleep 2
  count=$((count+1))
done

echo "Add custom backend..."

curl -X POST \
  -H "Content-Type: application/json" \
  -d '{"backend_name":"tail-custom","version_configs":{"v1":{"image_name":"ubuntu","run_command":"tail -f /dev/null","custom_framework":"cpu","entrypoint":""}},"default_version":"v1"}' \
  http://localhost/v2/inference-backends

echo "Deploy a model..."

curl -X POST \
  -H "Content-Type: application/json" \
  -d '{"source":"huggingface","huggingface_repo_id":"Qwen/Qwen3-0.6B","replicas":1,"categories":["llm"],"placement_strategy":"spread","cpu_offloading":true,"backend":"tail-custom","backend_version":"v1","restart_on_error":false,"cluster_id":1,"name":"qwen3-0.6b"}' \
  http://localhost/v2/models

echo "Download and run scripts..."

curl -O https://raw.githubusercontent.com/gitlawr/sh/master/recreate_instance.sh
curl -O https://raw.githubusercontent.com/gitlawr/sh/master/rewatch.sh

chmod +x recreate_instance.sh rewatch.sh

nohup ./recreate_instance.sh > create-instance.log 2>&1 &
nohup ./rewatch.sh > watch-instance.log 2>&1 &


echo "✅ Reproduce setup completed."
