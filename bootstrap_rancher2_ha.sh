#Script to bootstrap rancher 2.x HA in AWS
set -e

function prepare(){
  #precheck
  echo "Pre-checking..."
  command -v helm >/dev/null 2>&1 || { echo >&2 "helm(3) is required but it's not installed.  Please install it first."; exit 1; }
  command -v kubectl >/dev/null 2>&1 || { echo >&2 "kubectl is required but it's not installed.  Please install it first."; exit 1; }
  command -v aws >/dev/null 2>&1 || { echo >&2 "aws(cli) is required but it's not installed.  Please install it first."; exit 1; }
  aws sts get-caller-identity >/dev/null 2>&1 || ( echo "Unknown AWS identity. Please login to aws cli first." && exit 1 );

  rm -f ./cluster.rkestate
  rm -f ./kube_config_cluster.yml
  echo "Pre-checking done"


  DEFAULT_RANCHER_VERSION=2.3.3
  DEFAULT_INSTANCE_COUNT=1
  DEFAULT_INSTANCE_PREFIX=lawr
  DEFAULT_RANCHER_HOSTNAME=lawr.eng-cn.rancher.space



  echo "Please provide number of instances to bootstrap HA Rancher:($DEFAULT_INSTANCE_COUNT)"
  read INSTANCE_COUNT
  echo "Please provide prefix for AWS instance name:($DEFAULT_INSTANCE_PREFIX)"
  read INSTANCE_PREFIX
  echo "Please provide FQDN to access Rancher. It should be managable in route53:($DEFAULT_RANCHER_HOSTNAME)"
  read RANCHER_HOSTNAME
  echo "Please provide VERSION:($DEFAULT_RANCHER_VERSION)"
  read RANCHER_VERSION

  if [[ -z "$INSTANCE_COUNT" ]];then
    INSTANCE_COUNT=$DEFAULT_INSTANCE_COUNT
  fi
  if [[ -z "$INSTANCE_PREFIX" ]];then
    INSTANCE_PREFIX=$DEFAULT_INSTANCE_PREFIX
  fi
  if [[ -z "$RANCHER_HOSTNAME" ]];then
    RANCHER_HOSTNAME=$DEFAULT_RANCHER_HOSTNAME
  fi

}

function installInstances(){
  echo "launching EC2 instances..."

  for ((i=1; i<=$INSTANCE_COUNT; i ++))
  do
  # instanceIds[$i]=$(aws ec2 run-instances --query 'Instances[*].[InstanceId]' --output text --image-id ami-061eb2b23f9f8839c --count 1 --instance-type t2.medium --key-name lawrence-sing --security-group-ids sg-0054a580d9a434f40 --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value='$INSTANCE_PREFIX$i'}]')
  instanceIds[$i]=$(aws ec2 run-instances --query 'Instances[*].[InstanceId]' --output text --image-id ami-061eb2b23f9f8839c --block-device-mapping 'DeviceName=/dev/sda1,Ebs={VolumeSize=60}' --count 1 --instance-type t2.medium --key-name lawrence-sing --security-group-ids sg-0054a580d9a434f40 --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value='$INSTANCE_PREFIX$i'}]')
  done

  echo "Waiting for instances to be ready..."
  for ((i=1; i<=$INSTANCE_COUNT; i ++))
  do
    while [ "$state" != "running" -o "${ips[$i]}" == "" ];do
      state=$(aws ec2 describe-instances --instance-ids ${instanceIds[$i]} --query 'Reservations[0].Instances[*].State.Name' --output text)
      ips[$i]=$(aws ec2 describe-instances --instance-ids ${instanceIds[$i]} --query 'Reservations[0].Instances[*].PublicIpAddress' --output text)
      sleep 5
    done
  done

  echo "Resolving DNS record..."
  tmpfile=$(mktemp /tmp/route53.XXXXXX)
  cat << EOF >$tmpfile
  {
      "Comment": "CREATE/DELETE/UPSERT a record ",
      "Changes": [{
      "Action": "UPSERT",
          "ResourceRecordSet": {
              "Name": "$RANCHER_HOSTNAME",
              "Type": "A",
              "TTL": 300,
           "ResourceRecords": [{ "Value": "${ips[1]}"}]
  }}]
  }
EOF
  aws route53 change-resource-record-sets --hosted-zone-id Z3KOYTTM5A5VFV --change-batch file://$tmpfile > /dev/null
  rm -f $tmpfile

  # wait more time for ssh ready
  sleep 20

  echo "Installing docker..."
  for ((i=1; i<=$INSTANCE_COUNT; i ++))
  do
  ssh -o "StrictHostKeyChecking no" ubuntu@${ips[$i]} <<'ENDSSH'
  export DEBIAN_FRONTEND=noninteractive
  curl https://releases.rancher.com/install-docker/18.09.sh | sh
  sudo usermod -aG docker ubuntu
ENDSSH
  echo "finish installing docker in ${ips[$i]}"
  done

  #Prepare rke cluster file
  cat << EOF >cluster.yml
  nodes:
EOF
  for ((i=1; i<=$INSTANCE_COUNT; i ++))
  do
  cat << EOF >>cluster.yml
    - address: ${ips[$i]}
      user: ubuntu
      ssh_key_path: /Users/lipinghui/.ssh/lawrence-sing.pem
      role: [controlplane,worker,etcd]
EOF
  done

}

function rkeUp(){
  # install kubernetes cluster
  rke up
  cp ./kube_config_cluster.yml ~/.kube/config
}

function installRancher(){
  if [[ "$RANCHER_VERSION" == "skip" ]];then
    return
  fi
  # update repo
  helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
  kubectl create namespace cattle-system

  # install cert-manager
  kubectl apply -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.9/deploy/manifests/00-crds.yaml
  kubectl create namespace cert-manager
  kubectl label namespace cert-manager certmanager.k8s.io/disable-validation=true
  helm repo add jetstack https://charts.jetstack.io
  helm repo update
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --version v0.9.1
  kubectl -n cert-manager rollout status deploy/cert-manager

  sleep 20
  # install rancher
  echo "Installing rancher chart. Using \"$RANCHER_HOSTNAME\" as the FQDN for Rancher."
  helm install rancher rancher-latest/rancher \
    --namespace cattle-system \
    --version "$RANCHER_VERSION" \
    --set hostname="$RANCHER_HOSTNAME"

  kubectl -n cattle-system rollout status deploy/rancher
}



prepare
installInstances
rkeUp
installRancher




