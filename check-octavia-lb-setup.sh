#!/bin/bash

set -x
set -e

# set environment
export GOPATH=$HOME
export PATH="/usr/local/go/bin:$HOME/bin:$PATH"

install_apt() {
	sudo apt update
	sudo apt -y install "$@"
}

install_go() {
	GOLANG_VERSION=$1
	GOLANG_TARBALL=go${GOLANG_VERSION}.linux-$(dpkg --print-architecture).tar.gz

	if ! type go; then
		wget https://dl.google.com/go/${GOLANG_TARBALL}
		sudo tar -xf ${GOLANG_TARBALL} -C /usr/local
	fi
}

install_etcd() {
	ETCD_VERSION=v$1
	ETCD_TARBALL=etcd-${ETCD_VERSION}-linux-$(dpkg --print-architecture).tar.gz

	if ! type etcd; then
		wget https://github.com/coreos/etcd/releases/download/${ETCD_VERSION}/${ETCD_TARBALL}
		tar -xf ${ETCD_TARBALL}
		sudo cp -r etcd*/etcd{,ctl} /usr/local/bin
	fi
}

clear_iptables() {
	sudo iptables -F
	sudo iptables -X
	sudo iptables -t nat -F
	sudo iptables -t nat -X
	sudo iptables -t mangle -F
	sudo iptables -t mangle -X
	sudo iptables -P INPUT ACCEPT
	sudo iptables -P FORWARD ACCEPT
	sudo iptables -P OUTPUT ACCEPT
}

install_k8s() {
	K8S_VERSION=v$1
	K8S_TARBALL=${K8S_VERSION}.tar.gz
	K8S_SRC_DIR=$HOME/src/k8s.io/kubernetes
	K8S_BIN_DIR=$K8S_SRC_DIR/_output/local/bin/linux/$(dpkg --print-architecture)

	mkdir -p ${K8S_SRC_DIR}
	if [ ! -f $K8S_TARBALL ]; then
		wget https://github.com/kubernetes/kubernetes/archive/${K8S_TARBALL}
		tar -xf ${K8S_TARBALL} --strip 1 -C ${K8S_SRC_DIR}
	fi

	mkdir -p ${K8S_BIN_DIR}
	for i in `echo kubectl hyperkube`; do
		BIN_PATH="${K8S_BIN_DIR}/${i}"
		if [ ! -f $BIN_PATH ]; then
			wget https://storage.googleapis.com/kubernetes-release/release/${K8S_VERSION}/bin/linux/$(dpkg --print-architecture)/$i -O $BIN_PATH;
			chmod +x $BIN_PATH;
		fi
	done;

	sudo mkdir -p /etc/kubernetes/
	cat <<EOF > $HOME/cloud-config
[Global]
domain-name = $OS_USER_DOMAIN_NAME
tenant-id = $OS_PROJECT_ID
auth-url = $OS_AUTH_URL
password = $OS_PASSWORD
username = $OS_USERNAME
region = $OS_REGION_NAME
[LoadBalancer]
use-octavia = true
floating-network-id = $(openstack network list --external -f value -c ID | head -n 1)
subnet-id = $(openstack network list --internal -f value -c Subnets | head -n 1)
[BlockStorage]
bs-version = v2
ignore-volume-az = yes
EOF
	sudo mv $HOME/cloud-config /etc/kubernetes/cloud-config
}

install_openstack_provider() {
	K8S_OS_PROVIDER_BRANCH=$1
	K8S_OS_PROVIDER_TARBALL=${K8S_OS_PROVIDER_BRANCH}.tar.gz
	K8S_OS_PROVIDER_SRC_DIR=$HOME/src/k8s.io/cloud-provider-openstack

	mkdir -p ${K8S_OS_PROVIDER_SRC_DIR}
	if [ ! -f $K8S_OS_PROVIDER_TARBALL ]; then
		wget https://github.com/kubernetes/cloud-provider-openstack/archive/${K8S_OS_PROVIDER_TARBALL}
		tar -xf ${K8S_OS_PROVIDER_TARBALL} --strip 1 -C ${K8S_OS_PROVIDER_SRC_DIR}
	fi

	cd ${K8S_OS_PROVIDER_SRC_DIR}
	make build
}

# Sanity checks
if [ -z $OS_AUTH_URL ]; then
	echo "OpenStack environment variables missing"
	exit 1
fi

install_apt docker.io go-dep golang-cfssl haveged jq mercurial &
install_go 1.10.2 &
install_etcd 3.3.0 &
clear_iptables &
install_k8s 1.10.2 &
install_openstack_provider master &

wait

# setup k8s
export K8S_OS_PROVIDER_SRC_DIR=$HOME/src/k8s.io/cloud-provider-openstack
export K8S_SRC_DIR=$HOME/src/k8s.io/kubernetes
export K8S_LOG_DIR=$HOME/workspace/logs/kubernetes
export K8S_BIN_DIR=$K8S_SRC_DIR/_output/local/bin/linux/$(dpkg --print-architecture)
export KUBECTL=$K8S_SRC_DIR/_output/local/bin/linux/$(dpkg --print-architecture)/kubectl

# create environment variables
export ETCD_UNSUPPORTED_ARCH=arm64
export API_HOST_IP=$(ip route get 1.1.1.1 | awk '{print $7}')
export KUBELET_HOST="0.0.0.0"
export ALLOW_SECURITY_CONTEXT=true
export ENABLE_CRI=false
export ENABLE_HOSTPATH_PROVISIONER=true
export ENABLE_SINGLE_CA_SIGNER=true
export KUBE_ENABLE_CLUSTER_DNS=false
export LOG_LEVEL=4
# We want to use the openstack cloud provider
export CLOUD_PROVIDER=openstack
# We want to run a separate cloud-controller-manager for openstack
export EXTERNAL_CLOUD_PROVIDER=true
# DO NOT change the location of the cloud-config file. It is important for the old cinder provider to work
export CLOUD_CONFIG=/etc/kubernetes/cloud-config
# Specify the OCCM binary
export EXTERNAL_CLOUD_PROVIDER_BINARY="$PWD/openstack-cloud-controller-manager"
# location of where the kubernetes processes log their output
sudo mkdir -p ${K8S_LOG_DIR}
export LOG_DIR=${K8S_LOG_DIR}
# We need this for one of the conformance tests
export ALLOW_PRIVILEGED=true
# Just kick off all the processes and drop down to the command line
export ENABLE_DAEMON=true
export HOSTNAME_OVERRIDE=$(curl http://169.254.169.254/openstack/latest/meta_data.json | jq -r .name)
export MAX_TIME_FOR_URL_API_SERVER=5
# -E preserves the current env vars, but we need to special case PATH
# Must run local-up-cluster.sh under kubernetes root directory
pushd ${K8S_SRC_DIR}
sudo -E PATH=$PATH SHELLOPTS=$SHELLOPTS ./hack/local-up-cluster.sh -O
popd
# set up the config we need for kubectl to work
sudo ${KUBECTL} config set-cluster local --server=https://localhost:6443 --certificate-authority=/var/run/kubernetes/server-ca.crt
sudo ${KUBECTL} config set-credentials myself --client-key=/var/run/kubernetes/client-admin.key --client-certificate=/var/run/kubernetes/client-admin.crt
sudo ${KUBECTL} config set-context local --cluster=local --user=myself
sudo ${KUBECTL} config use-context local
# Hack for RBAC for all for the new cloud-controller process, we need to do better than this
sudo ${KUBECTL} create clusterrolebinding --user system:serviceaccount:kube-system:default kube-system-cluster-admin-1 --clusterrole cluster-admin
sudo ${KUBECTL} create clusterrolebinding --user system:serviceaccount:kube-system:pvl-controller kube-system-cluster-admin-2 --clusterrole cluster-admin
sudo ${KUBECTL} create clusterrolebinding --user system:serviceaccount:kube-system:cloud-node-controller kube-system-cluster-admin-3 --clusterrole cluster-admin
sudo ${KUBECTL} create clusterrolebinding --user system:serviceaccount:kube-system:cloud-controller-manager kube-system-cluster-admin-4 --clusterrole cluster-admin
sudo ${KUBECTL} create clusterrolebinding --user system:serviceaccount:kube-system:shared-informers kube-system-cluster-admin-5 --clusterrole cluster-admin
sudo ${KUBECTL} create clusterrolebinding --user system:kube-controller-manager  kube-system-cluster-admin-6 --clusterrole cluster-admin
# Run test
for test_case in internal external
do
  test_file="examples/loadbalancers/${test_case}-http-nginx.yaml"
  service_name="${test_case}-http-nginx-service"
  # Delete fake floating-network-id to use the default one in cloud config
  sed -i '/loadbalancer.openstack.org/d' "$test_file"
  sudo ${KUBECTL} create -f "$test_file"
  if ! service_name="$service_name" timeout 600 bash -c '
      while :
      do
          [[ -n $(sudo ${KUBECTL} describe service "$service_name" | awk "/LoadBalancer Ingress/ {print \$3}") ]] && break
          sleep 1
      done
      '
  then
      echo "Timed out to wait for $test_case loadbalancer services deployment!"
      sudo ${KUBECTL} describe pods
      sudo ${KUBECTL} describe services
      exit 1
  fi
  ingress_ip=$(sudo ${KUBECTL} describe service "$service_name" | awk "/LoadBalancer Ingress/ {print \$3}")
  if curl --retry 5 --retry-max-time 30 "http://$ingress_ip" | grep 'Welcome to nginx'
  then
      echo "$test_case lb services launched sucessfully!"
  else
      echo "$test_case lb services launched failed!"
      exit 1
  fi
done

# Clean up all the things
sudo apt -y install python-openstackclient python-octaviaclient
pushd ${K8S_OS_PROVIDER_SRC_DIR}
sudo ${KUBECTL} config use-context local
ext_lb_svc_uid=$(sudo ${KUBECTL} get services external-http-nginx-service -o=jsonpath='{.metadata.uid}') || true
int_lb_svc_uid=$(sudo ${KUBECTL} get services internal-http-nginx-service -o=jsonpath='{.metadata.uid}') || true
sudo ${KUBECTL} delete -f examples/loadbalancers/internal-http-nginx.yaml || true
sudo ${KUBECTL} delete -f examples/loadbalancers/external-http-nginx.yaml || true
for lb_svc_uid in $ext_lb_svc_uid $int_lb_svc_uid; do
    lb_name=$(echo $lb_svc_uid | tr -d '-' | sed 's/^/a/' | cut -c -32)
    openstack loadbalancer delete --cascade $lb_name || true
popd
