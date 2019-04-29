
#install docker to existing vm
echo "Please provide a node IP to bootstrap HA Rancher:"
read DEV_HOST
echo "Please provide FQDN for Rancher:"
read RANCHER_HOSTNAME

ssh -o "StrictHostKeyChecking no" ubuntu@$DEV_HOST <<'ENDSSH'
curl https://releases.rancher.com/install-docker/18.09.sh | sh
sudo usermod -aG docker ubuntu
ENDSSH

# install kubernetes cluster
rke up
cp ./kube_config_cluster.yml ~/.kube/config

# helm init
kubectl -n kube-system create serviceaccount tiller
kubectl create clusterrolebinding tiller \
  --clusterrole=cluster-admin \
  --serviceaccount=kube-system:tiller
hlm init --service-account tiller
kubectl -n kube-system  rollout status deploy/tiller-deploy

# update repo
hlm repo update

# install cert-manager
hlm install stable/cert-manager \
  --name cert-manager \
  --namespace kube-system \
  --version v0.5.2
kubectl -n kube-system rollout status deploy/cert-manager

# install rancher
echo "Using \"$RANCHER_HOSTNAME\" as the FQDN for Rancher."
hlm install rancher-latest/rancher \
  --name rancher \
  --namespace cattle-system \
  --set hostname=$RANCHER_HOSTNAME
kubectl -n cattle-system rollout status deploy/rancher
