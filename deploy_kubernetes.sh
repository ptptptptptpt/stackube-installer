#!/bin/bash
#
# Dependencies:
#
# - ``KUBERNETES_API_IP``, ``KEYSTONE_URL``,
# - ``CLUSTER_CIDR``, ``CLUSTER_GATEWAY``,
# - ``CONTAINER_CIDR``, ``FRAKTI_VERSION``,
# - ``KEYSTONE_ADMIN_URL``  must be defined
#

programDir=`dirname $0`
programDir=$(readlink -f $programDir)
parentDir="$(dirname $programDir)"
programDirBaseName=$(basename $programDir)


set -x

## install hyper
yum install -y libvirt || exit 1
if command -v /usr/bin/hyperd > /dev/null 2>&1; then
    echo "hyperd already installed on this host, using it."
else
    curl -sSL https://hypercontainer.io/install | bash  || exit 1
fi

cat > /etc/hyper/config << EOF
Kernel=/var/lib/hyper/kernel
Initrd=/var/lib/hyper/hyper-initrd.img
Hypervisor=qemu
StorageDriver=overlay
gRPCHost=127.0.0.1:22318

EOF



## install frakti
if command -v /usr/bin/frakti > /dev/null 2>&1; then
    echo "frakti already installed on this host, using it."
else
    curl -sSL https://github.com/kubernetes/frakti/releases/download/${FRAKTI_VERSION}/frakti -o /usr/bin/frakti  || exit 1
    chmod +x /usr/bin/frakti  || exit 1
fi

dockerInfo=`docker info ` || exit 1
cgroup_driver=`echo "${dockerInfo}" | awk '/Cgroup Driver/{print $3}' `
[ "${cgroup_driver}" ] || exit 1

echo "[Unit]
Description=Hypervisor-based container runtime for Kubernetes
Documentation=https://github.com/kubernetes/frakti
After=network.target
[Service]
ExecStart=/usr/bin/frakti --v=3 \
          --log-dir=/var/log/frakti \
          --logtostderr=false \
          --cgroup-driver=${cgroup_driver} \
          --listen=/var/run/frakti.sock \
          --streaming-server-addr=${KUBERNETES_API_IP} \
          --hyper-endpoint=127.0.0.1:22318
MountFlags=shared
#TasksMax=8192
LimitNOFILE=1048576
LimitNPROC=1048576
LimitCORE=infinity
TimeoutStartSec=0
Restart=on-abnormal
[Install]
WantedBy=multi-user.target
"  > /lib/systemd/system/frakti.service  || exit 1



## install kubelet
cat > /etc/yum.repos.d/kubernetes.repo << EOF
[kubernetes]
name=Kubernetes
baseurl=http://yum.kubernetes.io/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg
       https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF

setenforce 0
sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config  || exit 1
yum install -y kubelet-1.7.3-1 kubeadm-1.7.3-1 kubectl-1.7.3-1  || exit 1
systemctl enable kubelet  || exit 1

# configure_kubelet
unitFile='/etc/systemd/system/kubelet.service.d/10-kubeadm.conf'
sed -i '/^Environment="KUBELET_EXTRA_ARGS=/d'  ${unitFile}  || exit 1
sed -i '/\[Service\]/aEnvironment="KUBELET_EXTRA_ARGS=--container-runtime=remote --container-runtime-endpoint=/var/run/frakti.sock --feature-gates=AllAlpha=true"'  ${unitFile}  || exit 1



## start basic services
systemctl daemon-reload  || exit 1
systemctl enable hyperd frakti libvirtd  || exit 1
systemctl restart hyperd libvirtd  || exit 1
sleep 3
systemctl restart frakti  || exit 1
sleep 10
## check
hyperctl list  || exit 1
pgrep -f '/usr/bin/frakti'  || exit 1
[ -e /var/run/frakti.sock ]  || exit 1




## init k8s master {
sed -i "s|__KEYSTONE_URL__|${KEYSTONE_URL}|g" ${programDir}/kubeadm.yaml  || exit 1
sed -i "s|__POD_NET_CIDR__|${CLUSTER_CIDR}|g" ${programDir}/kubeadm.yaml  || exit 1
sed -i "s/__API_IP__/${KUBERNETES_API_IP}/g" ${programDir}/kubeadm.yaml  || exit 1

kubeadm init  --config ${programDir}/kubeadm.yaml  || exit 1

# Enable schedule pods on the master for testing.
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl taint nodes --all node-role.kubernetes.io/master-  || exit 1


sleep 10


## install stackube addons
kubectl -n kube-system delete deployment kube-dns  ||  exit 1
kubectl -n kube-system delete daemonset kube-proxy  ||  exit 1

source /etc/stackube/openstack/admin-openrc.sh   ||  exit 1
netList=`openstack network list --long -f value`  ||  exit 1
public_network=$(echo "${netList}" | grep External | grep ' br-ex ' | awk '{print $1}')
[ "${public_network}" ] || exit 1
nnn=`echo "${public_network}" | wc -l`
[ $nnn -gt 1 ] && exit 1

cat > ${programDir}/stackube-configmap.yaml <<EOF
kind: ConfigMap
apiVersion: v1
metadata:
  name: stackube-config
  namespace: kube-system
data:
  auth-url: "${KEYSTONE_ADMIN_URL}"
  username: "admin"
  password: "${OS_PASSWORD}"
  tenant-name: "admin"
  region: "RegionOne"
  ext-net-id: "${public_network}"
  plugin-name: "ovs"
  integration-bridge: "br-int"
  user-cidr: "${CLUSTER_CIDR}"
  user-gateway: "${CLUSTER_GATEWAY}"
  kubernetes-host: "${KUBERNETES_API_IP}"
  kubernetes-port: "6443"
EOF
kubectl create -f ${programDir}/stackube-configmap.yaml   ||  exit 1
kubectl create -f ${programDir}/../deployment/stackube.yaml  ||  exit 1
kubectl create -f ${programDir}/../deployment/stackube-proxy.yaml  ||  exit 1


sleep 15


export KUBECONFIG=/etc/kubernetes/admin.conf

aaa=`kubectl get csr --all-namespaces | grep Pending | awk '{print $1}'`
echo "$aaa"
if [ "$aaa" ]; then
    for i in $aaa; do
        kubectl certificate approve $i
    done
fi


kubectl get nodes
kubectl get csr --all-namespaces





exit 0
