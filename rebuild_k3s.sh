#!/bin/bash
set -e

# Usage:
#   ENV_VAR=... ./rebuild_k3s.sh
#
# Example:
#   Rebuild K3S using MySQL:
#     K3S_SERVERS="172.16.0.2" K3S_DATASTORE_ENDPOINT="mysql://username:password@tcp(hostname:3306)/database-name" rebuild_k3s.sh
#
# Environment variables:
#   - K3S_SERVERS
#     K3S server IPs in comma seperated format.
#     e.g., 172.16.0.1,172.16.0.2,172.16.0.3
#
#   - SSH_USER
#     The user to be used when connecting to k3s nodes. It should has sudo permission.
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
  command -v mysql >/dev/null 2>&1 || fatal "mysql client is required but is not found. Please install it first."

  if [[ -z "$K3S_SERVERS" ]];then
    fatal "Please provide K3S_SERVERS"
  fi
  if [[ -z "$K3S_DATASTORE_ENDPOINT" ]];then
    fatal "Please provide K3S_DATASTORE_ENDPOINT"
  fi
  if [[ -z "$SSH_USER" ]];then
    SSH_USER=root
  fi

  IFS=', ' read -r -a k3s_servers <<< "$K3S_SERVERS"
  re='mysql://([^:@]+):*([^:@]*)@[a-zA-Z]+\(([^:\)]+):*([0-9]*)\)/([^\?]+)'
  if [[ $K3S_DATASTORE_ENDPOINT =~ $re ]]; then 
    DB_USERNAME=${BASH_REMATCH[1]}; 
    DB_PASSWORD=${BASH_REMATCH[2]}; 
    DB_HOSTNAME=${BASH_REMATCH[3]}; 
    DB_PORT=${BASH_REMATCH[4]}; 
    DB_DATABASENAME=${BASH_REMATCH[5]}; 
  else
    fatal "Failed to parse datastore endpoint: $K3S_DATASTORE_ENDPOINT"
  fi

  if [[ ! -z "$K3S_DATASTORE_CAFILE" ]];then
    K3S_ARGS="$K3S_ARGS --datastore-cafile /var/lib/rancher/k3s/server/tls/datastore-ca.pem"
    MYSQL_ARGS="--ssl-ca=$K3S_DATASTORE_CAFILE"
  fi
  if [[ ! -z "$K3S_DATASTORE_CERTFILE" ]];then
    K3S_ARGS="$K3S_ARGS --datastore-certfile /var/lib/rancher/k3s/server/tls/datastore-cert.pem"
    MYSQL_ARGS="$MYSQL_ARGS --ssl-cert=$K3S_DATASTORE_CERTFILE"
  fi
  if [[ ! -z "$K3S_DATASTORE_KEYFILE" ]];then
    K3S_ARGS="$K3S_ARGS --datastore-keyfile /var/lib/rancher/k3s/server/tls/datastore-key.pem"
    MYSQL_ARGS="$MYSQL_ARGS --ssl-key=$K3S_DATASTORE_KEYFILE"
  fi
}

reset_nodes(){
  info "Resetting nodes from database"
  mysql -u$DB_USERNAME -h$DB_HOSTNAME -P$DB_PORT -p$DB_PASSWORD -D$DB_DATABASENAME $MYSQL_ARGS \
  -e "delete from kine where name like '/registry/minions%';
      delete from kine where name like '/registry/masterleases%';
      delete from kine where name like '/registry/leases/kube-node-lease%';"
}


prepare_certs(){
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
  ssh $SSH_USER@${k3s_servers[0]} &>/dev/null <<ENDSSH
  sudo k3s kubectl label node --all node-role.kubernetes.io/worker=worker
ENDSSH
}

precheck
reset_nodes
prepare_certs
setup_k3s
update_config
