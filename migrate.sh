#!/bin/bash
set -e

# Usage:
#   ENV_VAR=... ./migrate.sh
#
# Example:
#   Migrate from RKE to K3S:
#     RKE_SERVERS="172.16.0.1" K3S_SERVERS="172.16.0.2" K3S_DATASTORE_ENDPOINT="mysql://username:password@tcp(hostname:3306)/database-name" migrate.sh
#
# Environment variables:
#   - RKE_SERVERS
#     RKE server IPs in comma seperated format.
#     e.g., 172.16.0.1,172.16.0.2,172.16.0.3
#
#   - K3S_SERVERS
#     K3S server IPs in comma seperated format.
#     e.g., 172.16.0.1,172.16.0.2,172.16.0.3
#
#   - RKE_NETWORK_PLUGIN
#     Network plugin used in the RKE cluster.
#     Default: canal.
#
#   - SSH_USER
#     The user to be used when connecting to rke & k3s nodes. It should has sudo permission.
#     Default: root.
#
#   - K3S_DATASTORE_ENDPOINT
#     Specify Mysql endpoint in K3S datastore format.
#     e.g., mysql://username:password@tcp(hostname:3306)/database-name
#
#   - K3S_DATASTORE_CAFILE
#     TLS Certificate Authority (CA) file used to help secure communication with the datastore.
#
#   - K3S_DATASTORE_CERTFILE
#     TLS certificate file used for client certificate based authentication to your datastore.
#
#   - K3S_DATASTORE_KEYFILE
#     TLS key file used for client certificate based authentication to your datastore.
#
#   - K3S_ARGS
#     Optional arguments for running K3S server command


# --- helper functions for logs ---
info()
{
  echo '[INFO] ' "$@"
}
warn()
{
  echo '[WARN] ' "$@" >&2
}
fatal()
{
  echo '[ERROR] ' "$@" >&2
  exit 1
}

precheck(){
  info "Prechecking"
  command -v etcd2sql >/dev/null 2>&1 || fatal "etcd2sql is required but is not found. Please install it first."

  if [[ -z "$RKE_SERVERS" ]];then
    fatal "Please provide RKE_SERVERS"
  fi
  if [[ -z "$K3S_SERVERS" ]];then
    fatal "Please provide K3S_SERVERS"
  fi
  if [[ -z "$K3S_DATASTORE_ENDPOINT" ]];then
    fatal "Please provide K3S_DATASTORE_ENDPOINT"
  fi
  if [[ -z "$SSH_USER" ]];then
    SSH_USER=root
  fi
  if [[ -z "$RKE_NETWORK_PLUGIN" ]];then
    RKE_NETWORK_PLUGIN=canal
  fi
  if [[ ! -z "$K3S_DATASTORE_CAFILE" ]];then
    K3S_ARGS="$K3S_ARGS --datastore-cafile /var/lib/rancher/k3s/server/tls/datastore-ca.pem"
    ETCD_TO_SQL_ARGS="--datastore-cafile $K3S_DATASTORE_CAFILE"
  fi
  if [[ ! -z "$K3S_DATASTORE_CERTFILE" ]];then
    K3S_ARGS="$K3S_ARGS --datastore-certfile /var/lib/rancher/k3s/server/tls/datastore-cert.pem"
    ETCD_TO_SQL_ARGS="$ETCD_TO_SQL_ARGS --datastore-certfile $K3S_DATASTORE_CERTFILE"
  fi
  if [[ ! -z "$K3S_DATASTORE_KEYFILE" ]];then
    K3S_ARGS="$K3S_ARGS --datastore-keyfile /var/lib/rancher/k3s/server/tls/datastore-key.pem"
    ETCD_TO_SQL_ARGS="$ETCD_TO_SQL_ARGS --datastore-keyfile $K3S_DATASTORE_KEYFILE"
  fi

  IFS=', ' read -r -a rke_servers <<< "$RKE_SERVERS"
  IFS=', ' read -r -a k3s_servers <<< "$K3S_SERVERS"
  ETCD_ENDPOINTS=$(printf "%s:2379," "${rke_servers[@]}"|sed 's/.$//')
}

stop_rke_apiserver(){
    info "Trying to stop kube-apiserver in rke nodes"
  for ip in "${rke_servers[@]}"
  do
    ssh -o "StrictHostKeyChecking no" $SSH_USER@$ip &>/dev/null <<'ENDSSH'
    [ "$(sudo docker ps -a | grep kube-apiserver)" ] && sudo docker stop kube-apiserver
ENDSSH
  done
}

prepare_certs(){
  info "Fetching SA key and certs for etcd from rke nodes"
  ssh $SSH_USER@${rke_servers[0]} &>/dev/null <<'ENDSSH'
  mkdir /tmp/rkecerts
  sudo cp /etc/kubernetes/ssl/{kube-ca.pem,kube-node.pem,kube-node-key.pem,kube-service-account-token-key.pem} /tmp/rkecerts
  sudo chmod 644 /tmp/rkecerts/*
ENDSSH
  scp $SSH_USER@${rke_servers[0]}:/tmp/rkecerts/{kube-ca.pem,kube-node.pem,kube-node-key.pem,kube-service-account-token-key.pem} .
  ssh $SSH_USER@${rke_servers[0]} rm -r /tmp/rkecerts

  info "Distributing SA key to K3S nodes"
  for ip in "${k3s_servers[@]}"
  do
    scp kube-service-account-token-key.pem $SSH_USER@$ip:/tmp/
    ssh $SSH_USER@$ip &>/dev/null <<'ENDSSH'
    sudo mkdir -p /var/lib/rancher/k3s/server/tls
    sudo mv /tmp/kube-service-account-token-key.pem /var/lib/rancher/k3s/server/tls/service.key
ENDSSH
  done

  for ip in "${k3s_servers[@]}"
  do
    if [[ ! -z "$K3S_DATASTORE_CAFILE" ]];then
      scp $K3S_DATASTORE_CAFILE $SSH_USER@$ip:/tmp/datastore-ca.pem
      ssh $SSH_USER@$ip &>/dev/null <<'ENDSSH'
      sudo mv /tmp/datastore-ca.pem /var/lib/rancher/k3s/server/tls/
ENDSSH
    fi
    if [[ ! -z "$K3S_DATASTORE_CERTFILE" && ! -z "$K3S_DATASTORE_KEYFILE" ]];then
      scp $K3S_DATASTORE_CERTFILE $SSH_USER@$ip:/tmp/datastore-cert.pem
      scp $K3S_DATASTORE_KEYFILE $SSH_USER@$ip:/tmp/datastore-key.pem
      ssh $SSH_USER@$ip &>/dev/null <<'ENDSSH'
      sudo mv /tmp/{datastore-cert.pem,datastore-key.pem} /var/lib/rancher/k3s/server/tls/
ENDSSH
    fi
  done

}

migrate_data(){
  info "Migrating data from etcd to MySQL"
  etcd2sql --endpoints $ETCD_ENDPOINTS --key kube-node-key.pem --cert kube-node.pem --cacert kube-ca.pem $ETCD_TO_SQL_ARGS $K3S_DATASTORE_ENDPOINT
}

setup_k3s(){
  for ip in "${k3s_servers[@]}"
  do
    info "setting up K3S in $ip"
    ssh $SSH_USER@$ip <<ENDSSH
    curl -sfL https://get.k3s.io | sh -s - server \
    --disable coredns,servicelb,traefik,local-storage,metrics-server \
    --flannel-backend=none \
    --datastore-endpoint="$K3S_DATASTORE_ENDPOINT" $K3S_ARGS
ENDSSH
  done
}

update_config(){
  # label K3S nodes and update cannal configuration
  ssh $SSH_USER@${k3s_servers[0]} &>/dev/null <<ENDSSH
  sudo k3s kubectl label node --all node-role.kubernetes.io/worker=worker
ENDSSH

  if [[ "$RKE_NETWORK_PLUGIN" = "canal" ]];then
    ssh $SSH_USER@${k3s_servers[0]} &>/dev/null <<ENDSSH
    sudo k3s kubectl get configmap/canal-config -n kube-system -o yaml|sed 's/\/etc\/kubernetes\/ssl\/kubecfg-kube-node.yaml/\/var\/lib\/rancher\/k3s\/agent\/kubelet.kubeconfig/' |sudo k3s kubectl apply -f -
    sudo k3s kubectl delete po -n kube-system -l k8s-app=canal
ENDSSH
  fi
  if [[ "$RKE_NETWORK_PLUGIN" = "calico" ]];then
    ssh $SSH_USER@${k3s_servers[0]} &>/dev/null <<ENDSSH
    sudo k3s kubectl get configmap/calico-config -n kube-system -o yaml|sed 's/\/etc\/kubernetes\/ssl\/kubecfg-kube-node.yaml/\/var\/lib\/rancher\/k3s\/agent\/kubelet.kubeconfig/' |sudo k3s kubectl apply -f -
    sudo k3s kubectl delete po -n kube-system -l k8s-app=calico-node
ENDSSH
  fi
}

precheck
stop_rke_apiserver
prepare_certs
migrate_data
setup_k3s
update_config
