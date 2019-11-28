#!/bin/bash

# Set up k8s, including ingress controller OR load balancer.
# Invoked on each node in the cluster, either master or worker.
# Arguments to this script, if any, are node ips, the first being master's.
#
# This script can be run sequentially on each node.  After master
# node's execution, the nodeJoinFile is created which contains info
# for worker nodes to join the cluster.  After copying the file to
# a worker node, this script can be executed.
#
# This script can also be run parallelly on each node, given there is
# a shared file system for the nodes.  The k8s-local-setup.sh
# script, invoked here, determines the location of nodeJoinFile
# in the shared file system if there is one.  The worker nodes wait
# till nodeJoinFile is generated by the master node.

DEBUG=1  # show command output if not 0

# if not running as root, sudo
if [[ $EUID -ne 0 ]]; then
  sudo $0 $@
  exit
fi

# figure out the directory of this script so that sub scripts can be found.
# copied directly from stackoverflow (many thanks).
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  # if $SOURCE was a relative symlink,
  # we need to resolve it relative to the path where the symlink file was located
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"

# Non-zero number of node ips means the execution is on master.
# However, k8s-local-setup.sh may change $onMaster according to local conditions.
onMaster=0
if [[ $# -ne 0 ]]; then
  nodes=("$@")
  onMaster=1
fi

# Following variables may also be modified by k8s-local-setup.sh per local environment.
KUBECONFIG_DIR=~/.kube
KUBECONFIG_FILE=$KUBECONFIG_DIR/config
k8sTmpDir=~/k8s
logFile=$k8sTmpDir/$(hostname -s).setup.log

# important: kubeadm init's "plaese join me" info is dumped in this file.
# Work nodes should be able to find it.
nodeJoinFile=$k8sTmpDir/nodeJoinFile

# kubeadm init options
pod_network_cidr='--pod-network-cidr=10.244.0.0/16'
#pod_network_cidr=''
service_cidr=''
useIngressController=1

# local specific script.  It may modify the variable above,
# configure network, etc.  It can be a symlink to a script
# in a separate git repository for local k8s configuration.
. $DIR/k8s-local-setup.sh

printVariables() {
echo on master: $onMaster
echo number of nodes: ${#nodes[@]}
for node in "${nodes[@]}"; do
   echo "$node"
done

echo KUBECONFIG_DIR: $KUBECONFIG_DIR
echo KUBECONFIG_FILE: $KUBECONFIG_FILE
echo k8sTmpDir: $k8sTmpDir
echo logFile: $logFile
echo nodeJoinFile: $nodeJoinFile
}
if (($DEBUG)); then
  printVariables
fi

sudo_user_uid=$(id $SUDO_USER -u)
sudo_user_gid=$(id $SUDO_USER -g)

# prepare for nodeJoinFile location
nodeJoinFileDir=$(dirname $nodeJoinFile)
mkdir -p $nodeJoinFileDir
chown ${sudo_user_uid}:${sudo_user_gid} $nodeJoinFileDir

# prepare kube config dir.
mkdir -p $KUBECONFIG_DIR
chown ${sudo_user_uid}:${sudo_user_gid} $KUBECONFIG_DIR

# tmp directory ready
mkdir -p $k8sTmpDir
chown ${sudo_user_uid}:${sudo_user_gid} $k8sTmpDir

# log file ready
rm -r $logFile >& /dev/null
touch $logFile

want_cmd_output=0  # caller should set to non-zero if cmd output is wanted
cmd_fail_ok=0  # do not exit when cmd fails
cmd_output=warning_uninitialized
cmd_rc=-1
exec_cmd() {
  if (($DEBUG)); then
    echo "### $@"
  fi

  cmd_output=warning_uninitialized

  if (($want_cmd_output)); then
    cmd_output=$(eval $@)
    echo "$cmd_output"
  elif (($DEBUG)); then
    eval $@
  else
    eval $@ > /dev/null
  fi

  cmd_rc=$?
  if [[ $cmd_rc -ne 0 && $cmd_fail_ok -eq 0 ]]; then
    echo "### cmd failed. exit"
    exit -1
  fi

  want_cmd_output=0
  cmd_fail_ok=0
} &>> $logFile
# replace the line above with a single "}" to see output directly
#}

configIngressController() {
  exec_cmd echo config ingress controller

  # We the ingress-nginx controller
  # https://kubernetes.github.io/ingress-nginx/deploy/
  # (not to be confused with https://github.com/nginxinc/kubernetes-ingress)
  # with hostNetwork on (using the worker nodes' ips as entry point)
  # The controller is deployed as daemonSet so that each node has
  # exactly one controller pod.

  # To edit the recommended configmap, first get yq, a yaml editor
  exec_cmd add-apt-repository ppa:rmescandon/yq -y
  exec_cmd apt update
  exec_cmd apt install yq -y

  # files involved
  original=$k8sTmpDir/mandatory.yaml
  modified=$k8sTmpDir/mandatory_modified.yaml
  mod_script=$k8sTmpDir/mod_script.yaml

  # compose a modification yq script
  cat > $mod_script <<EOF
kind: DaemonSet
spec.template.spec.hostNetwork: true
EOF

  # get the starndard configmap
  exec_cmd wget -O $original https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/mandatory.yaml

  # the download yaml file contains multiple documents, one of them is "Deployment" of
  # the ingress controller.  Find its index in the file.
  IFS=$'\n', read -rd '' -a kinds <<< $(yq r -d'*' $original kind)
  index=0
  for kind in "${kinds[@]}"
  do
    if [[ $kind =~ "Deployment" ]]; then
      break
    fi
    ((index++))
  done

  # apply the mod_script to original
  exec_cmd "yq w -s $mod_script -d $index $original > $modified"
  # unfortunately it's not clear how to put "delete" into the yq script.
  # now delete the "replicas" in-place or kubectl will give warning.
  exec_cmd yq d -i $modified -d $index spec.replicas

  # use the modified file and the original nodeport file for bare-metal
  # this will allow all worder nodes to become entry points
  exec_cmd kubectl apply -f $modified
  exec_cmd kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/baremetal/service-nodeport.yaml
}

configLoadBalancer() {
  exec_cmd echo config load balancer

  # deploy load balancer
  exec_cmd kubectl apply -f https://raw.githubusercontent.com/google/metallb/v0.8.1/manifests/metallb.yaml

  # make load balancer config file (host ips will be added later)
  metallbConfig=$k8sTmpDir/metallbConfig.yaml
  cat > $metallbConfig <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
EOF

  # add host ips in the cluster as public ips
  for node in "${nodes[@]}"; do
    echo "      - ${node}/32" >> $metallbConfig

    # NOTE: The original design is to add ip addresses of all nodes
    # as usable entry points.  But it seems easier to explain to
    # the user that a service is accessed via master node's ip plus
    # a specific port number.  Therefore break after adding master's ip.
    # -- czang
    break
  done

  # config load balancer.
  exec_cmd kubectl apply -f $metallbConfig
}

# this function runs on master only
afterKubeInit() {
  # copy kube config file to user's space and set KUBECONFIG env
  exec_cmd cp /etc/kubernetes/admin.conf $KUBECONFIG_FILE
  exec_cmd chown ${sudo_user_uid}:${sudo_user_gid} $KUBECONFIG_FILE
  exec_cmd chmod g+r $KUBECONFIG_FILE
  exec_cmd export KUBECONFIG=$KUBECONFIG_FILE

  # use weave addon for networking
  k8s_app="https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"
  exec_cmd kubectl apply -f $k8s_app

  # set master as a worker node, too, if it's the only node
  if [[ ${#nodes[@]} -eq 1 ]]; then
    exec_cmd kubectl taint nodes --all node-role.kubernetes.io/master-
  fi

  if [ $useIngressController -eq 1 ]; then
    configIngressController
  else
    configLoadBalancer
  fi

  # post the cluster ready message, if any, on the "wall"
  if [ "$wallCommand" ]; then
    $wallCommand
  fi
}

# this function runs on work only
wait4joinFile() {
  elapsed=0
  echo wait to join the master

  while true; do
    sleep 5
    elapsed=$((elapsed+5))
    echo have waited $elapsed seconds

    # It's observed that nodeJoinFile in shared file system may not be
    # noticed by other nodes soon enough.  Adding "ls parentDir"
    # forces the parent directory to sync-up.
    ls $(dirname $nodeJoinFile) > /dev/null
    if [ -f $nodeJoinFile ]; then
      break
    fi
  done

  # NOTE: The join command is the last two lines in the output of
  # kubeadm.  But replying on this is fragile.
  twoLines=$(tail -2 $nodeJoinFile)
  # remove backslash that separates two lines
  joinCmd=$(echo $twoLines | sed 's/\\/ /')
}

if [ $onMaster -eq 1 ]; then
  exec_cmd echo k8s setup start on MASTER node
  rm -f $nodeJoinFile
else
  exec_cmd echo k8s setup start on WORKER node
fi
exec_cmd date

############## install docker

exec_cmd apt-get update

exec_cmd DEBIAN_FRONTEND=noninteractive apt-get install -y apt-transport-https ca-certificates curl software-properties-common

want_cmd_output=1
exec_cmd curl -fsSL https://download.docker.com/linux/ubuntu/gpg
exec_cmd apt-key add <<< "$cmd_output"

dep_path="deb https://download.docker.com/linux/ubuntu $(lsb_release -cs)  stable"
exec_cmd add-apt-repository ${dep_path@Q}

exec_cmd apt-get update
exec_cmd apt-get install -y docker-ce=18.06.2~ce~3-0~ubuntu

cat > /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

exec_cmd systemctl daemon-reload
exec_cmd systemctl restart docker

# add the user into docker group
exec_cmd usermod -aG docker $(id $SUDO_USER -un)
# If we just exec newgrp, then we'll enter a new shell by default.
# Avoid getting into a shell by letting newgrp do something unimportant.
newgrp - docker <<EONG
echo "added user $SUDO_USER into docker group"
EONG

############## install k8s

# the key is binary, better not let it go stdout
tmpFile=$(mktemp /tmp/k8s-apt-key.XXXXXX)
exec_cmd curl -s --output $tmpFile https://packages.cloud.google.com/apt/doc/apt-key.gpg
exec_cmd apt-key add $tmpFile
rm -f $tmpFile

dep_path="deb http://apt.kubernetes.io/ kubernetes-xenial main"
exec_cmd add-apt-repository ${dep_path@Q}

exec_cmd apt-get install -y kubelet kubeadm kubectl
exec_cmd apt-mark hold kubelet kubeadm kubectl

# NOTE: k8s ask swap to be turned off.  That may be trouble.
exec_cmd swapoff -a

if [ $onMaster -eq 1 ]; then
  # on master
  want_cmd_output=1
  exec_cmd kubeadm init $pod_network_cidr $service_cidr --v=5
  echo "$cmd_output" > $nodeJoinFile

  # set up network, load balancer or ingress controller.
  afterKubeInit
else
  # on worker.  wait for nodeJoinFile to appear and then join.
  wait4joinFile
  exec_cmd $joinCmd --v=5
fi

exit
