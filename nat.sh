#!/bin/bash

# This script is invoked by the setup.sh script to set up k8s on
# an individual node, either the master node or a worker nodes.
# If used manually:
#
# On the master: "sudo nodeSetup.sh" or from another host do
# ssh sshUser@master 'sudo bash -s' < nodeSetup.sh
# Upon completion, the script will generate a file "node_signin"
# in its working directory on the master node.  At the end of
# the file, the "kubeadm join" command will be used by the
# worker nodes to join the cluster.
#
# On a worker: "sudo nodeSetup.sh 'kubeadm join ...'" or
# ssh sshUser@workder 'sudo bash -s' < nodeSetup.sh 'kubeadm join ...'
#
# To use exec_cmd on an echo command with redirection, add quotes like
# exec_cmd "echo abc > xyz"

# if not running as root, sudo
if [[ $EUID -ne 0 ]]; then
  sudo $0
  exit
fi

sleep 5

. /etc/profile

ip route add default via 10.71.0.3 dev enp2s4 onlink
ip route del default via 10.92.0.1 dev enp2s4
unset http_proxy
unset https_proxy
unset no_proxy

mv /etc/apt/apt.conf /etc/apt/apt.conf.not_necessary_with_NAT

# hostname is like h0.<exp>.<proj>.<rest>
IFS=. read -r host exp proj rest <<< $(hostname)
KUBECONFIG_DIR=/proj/$proj/exp/$exp/k8s
KUBECONFIG_FILE=$KUBECONFIG_DIR/config
nodeJoinFileDir=/proj/$proj/exp/$exp/tmp
nodeJoinFile=$nodeJoinFileDir/nodeJoinFile
k8sTmpDir=/proj/$proj/exp/$exp/tmp
logFile=/proj/$proj/exp/$exp/logs/$host.k8s.setup.log

rm -r $logFile
touch $logFile

DEBUG=1  # show command output if not 0
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
# replace the line above with a single "}" to observe command's output
# }

# create a service to clean up the join file generated by master
cat > /etc/systemd/system/k8s-cleanup.service <<EOF
[Unit]
Description=Delete-${nodeJoinFile}-at-shutdown
Before=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/bin/true
ExecStop=/bin/rm -f $nodeJoinFile

[Install]
WantedBy=shutdown.target
EOF

afterKubeInit() {
  # copy the config file to project space and set KUBECONFIG env
  sudo_user_uid=$(id $SUDO_USER -u)
  sudo_user_gid=$(id $SUDO_USER -g)
  exec_cmd mkdir -p $KUBECONFIG_DIR
  exec_cmd cp /etc/kubernetes/admin.conf $KUBECONFIG_FILE
  exec_cmd chown ${sudo_user_uid}:${sudo_user_gid} $KUBECONFIG_DIR
  exec_cmd chown ${sudo_user_uid}:${sudo_user_gid} $KUBECONFIG_FILE
  exec_cmd chmod g+r $KUBECONFIG_FILE
  exec_cmd export KUBECONFIG=$KUBECONFIG_FILE

  # use weave addon for networking
  k8s_app="https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"
  exec_cmd kubectl apply -f $k8s_app

  # deploy load balancer
  exec_cmd kubectl apply -f https://raw.githubusercontent.com/google/metallb/v0.8.1/manifests/metallb.yaml

  # make load balancer config file  (host ips will be added later)
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
  . /etc/emulab/paths.sh
  hostCount=0
  while IFS= read -r line; do
    read type nickname hostname rest <<< "$line";
    if [ $type == H ]; then
      ip=$(getent hosts $hostname | awk '{ print $1 }')
      echo "      - ${ip}/32" >> $metallbConfig
      hostCount=$((hostCount+1))
    fi
  done < $BOOTDIR/ltpmap

  # set master to a working node
  if [[ $hostCount -eq 1 ]]; then
    exec_cmd kubectl taint nodes --all node-role.kubernetes.io/master-
  fi

  # config load balancer. All host ips in the cluster are usable
  exec_cmd kubectl apply -f $metallbConfig
}

wait4joinFile() {
  elapsed=0
  echo wait to join the master

  while true; do
    sleep 5
    elapsed=$((elapsed+5))
    echo have waited $elapsed seconds

    # it's observed that the share nodeJoinFile may not be
    # noticed by other nodes soon enough.  Adding a "ls parentDir"
    # seems to help
    ls $nodeJoinFileDir > /dev/null
    if [ -f $nodeJoinFile ]; then
      break
    fi
  done
  twoLines=$(tail -2 $nodeJoinFile)
  # remove backslash that separates two lines
  joinCmd=$(echo $twoLines | sed 's/\\/ /')
}

if [ $(hostname -s) == "h0" ]; then
  exec_cmd echo k8s setup start on MASTER node
  rm -f $nodeJoinFile
  onMaster=1
  # start the cleanup service on master
  sudo systemctl start k8s-cleanup
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

#dep_path="deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs)  stable"
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
# avoid getting into a new shell with newgrp
newgrp - docker <<EONG
echo "### newgrp - docker"
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

exec_cmd swapoff -a

if [ $onMaster ]; then
  # on master
  want_cmd_output=1
  # exec_cmd kubeadm init --pod-network-cidr=10.244.0.0/24 --service-cidr=10.224.0.0/24 --v=5
  # exec_cmd kubeadm init --pod-network-cidr=10.244.0.0/16 --v=5
  exec_cmd kubeadm init --pod-network-cidr=192.168.10.0/24 --service-cidr=192.168.11.0/24 --v=5
  echo "$cmd_output" > $nodeJoinFile

  # get network, load balancer and context ready
  afterKubeInit

else
  # on worker.  wait for master to be ready then join
  wait4joinFile
  exec_cmd $joinCmd --v=5
fi

exit
