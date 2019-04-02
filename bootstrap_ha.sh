
#install docker to existing vm
if [ "$DEV_HOST" = "" ]; then
echo "Please provide node IP for DEV_HOST:"
read DEV_HOST
fi
awssh ubuntu@$DEV_HOST <<'ENDSSH'
curl https://releases.rancher.com/install-docker/18.09.sh | sh
sudo usermod -aG docker ubuntu
ENDSSH

# install kubernetes cluster
rke up
cpkb

# helm init
kubectl -n kube-system create serviceaccount tiller
kubectl create clusterrolebinding tiller \
  --clusterrole=cluster-admin \
  --serviceaccount=kube-system:tiller
hlm init --service-account tiller
kubectl -n kube-system  rollout status deploy/tiller-deploy

# install cert-manager
hlm install stable/cert-manager \
  --name cert-manager \
  --namespace kube-system \
  --version v0.5.2
kubectl -n kube-system rollout status deploy/cert-manager

# install rancher
if [ "$RANCHER_HOSTNAME" = "" ]; then
echo "Please provide FQDN for Rancher:"
read RANCHER_HOSTNAME
fi
echo "Using \"$RANCHER_HOSTNAME\" as the FQDN for Rancher."
hlm install rancher-latest/rancher \
  --name rancher \
  --namespace cattle-system \
  --set hostname=$RANCHER_HOSTNAME
kubectl -n cattle-system rollout status deploy/rancher
