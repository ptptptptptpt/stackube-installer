#!/bin/bash

programDir=`dirname $0`
programDir=$(readlink -f $programDir)
parentDir="$(dirname $programDir)"
programDirBaseName=$(basename $programDir)


function usage {
    echo "
Usage:
   bash $(basename $0) CONFIG_FILE
"
}


function install_docker {
    systemctl start docker &> /dev/null
    sleep 2
    docker info &> /dev/null
    if [ "$?" != "0" ]; then 
        cat > /etc/yum.repos.d/docker.repo  << EOF
[docker-repo]
name=Docker main Repository
baseurl=https://yum.dockerproject.org/repo/main/centos/7
enabled=1
gpgcheck=1
gpgkey=https://yum.dockerproject.org/gpg
EOF
        yum install docker-engine-1.12.6 docker-engine-selinux-1.12.6 -y || return 1
        #sed -i 's|ExecStart=.*|ExecStart=/usr/bin/dockerd  --storage-opt dm.mountopt=nodiscard --storage-opt dm.blkdiscard=false|g' /usr/lib/systemd/system/docker.service
        sed -i 's|ExecStart=.*|ExecStart=/usr/bin/dockerd  -s overlay |g' /usr/lib/systemd/system/docker.service
        systemctl daemon-reload  || return 1
        systemctl enable docker || return 1
        systemctl start  docker || return 1
    fi

    docker info &> /dev/null || return 1
}


function deploy_openstack_keystone {
    echo "Deploying OpenStack Keystone..."
    /bin/bash ${programDir}/deploy_openstack_keystone.sh
    if [ "$?" == "0" ]; then
        echo -e "\nOpenStack Keystone deployed successfully!\n"
    else
        echo -e "\nOpenStack Keystone deployed failed!\n"
        return 1
    fi

    yum install centos-release-openstack-ocata.noarch -y  || return 1
    yum install python-openstackclient  || return 1

    source /etc/stackube/openstack/admin-openrc.sh  || return 1
    openstack endpoint list
}


function deploy_openstack_neutron {
    echo "Deploying OpenStack Neutron..."
    /bin/bash ${programDir}/deploy_openstack_neutron.sh
    if [ "$?" == "0" ]; then
        echo -e "\nOpenStack Neutron deployed successfully!\n"
    else
        echo -e "\nOpenStack Neutron deployed failed!\n"
        return 1
    fi

    sleep 10

    yum install openvswitch -y  || return 1
    ovs-vsctl show

    source /etc/stackube/openstack/admin-openrc.sh  || return 1
    openstack network create --external --provider-physical-network physnet1 --provider-network-type flat br-ex  || return 1
    openstack network list
    openstack subnet list

}


function deploy_ceph {
    echo "Deploying ceph..."
    /bin/bash ${programDir}/deploy_ceph.sh
    if [ "$?" == "0" ]; then
        echo -e "\nCeph deployed successfully!\n"
    else
        echo -e "\nCeph deployed failed!\n"
        return 1
    fi
}


function deploy_openstack_cinder {
    echo "Deploying OpenStack Cinder..."
    /bin/bash ${programDir}/deploy_openstack_cinder.sh
    if [ "$?" == "0" ]; then
        echo -e "\nOpenStack Cinder deployed successfully!\n"
    else
        echo -e "\nOpenStack Cinder deployed failed!\n"
        return 1
    fi
}


function deploy_kubernetes {
    echo "Deploying Kubernetes..."
    /bin/bash ${programDir}/deploy_kubernetes.sh
    if [ "$?" == "0" ]; then
        echo -e "\nKubernetes deployed successfully!\n"
    else
        echo -e "\nKubernetes deployed failed!\n"
        return 1
    fi

}






######################################
# main
######################################

## check distro
source ${programDir}/lib_common.sh || { echo "Error: 'source ${programDir}/lib_common.sh' failed!"; exit 1; }
MSG='Sorry, only CentOS 7.x supported for now.'
if ! is_fedora; then
    echo ${MSG}; exit 1
fi
mainVersion=`echo ${os_RELEASE} | awk -F\. '{print $1}' `
if [ "${os_VENDOR}" == "CentOS" ] && [ "${mainVersion}" == "7" ]; then
    true
else
    echo ${MSG}; exit 1
fi


## config
[ "$1" ] || { usage; exit 1; }
[ -f "$1" ] || { echo "Error: $1 not exists or not a file!"; exit 1; }

source $(readlink -f $1) || { echo "'source $(readlink -f $1)' failed!"; exit 1; }
[ "${API_IP}" ] || { echo "Error: API_IP not defined!"; exit 1; }
[ "${KUBERNETES_API_IP}" ] || { echo "Error: KUBERNETES_API_IP not defined!"; exit 1; }
[ "${NEUTRON_EXT_IF}" ] || { echo "Error: NEUTRON_EXT_IF not defined!"; exit 1; }

export API_IP
export NEUTRON_EXT_IF
export KUBERNETES_API_IP

export MYSQL_ROOT_PWD=${MYSQL_ROOT_PWD:-MysqlRoot123}
export MYSQL_KEYSTONE_PWD=${MYSQL_KEYSTONE_PWD:-MysqlKeystone123}
export KEYSTONE_ADMIN_PWD=${KEYSTONE_ADMIN_PWD:-KeystoneAdmin123}
export RABBITMQ_PWD=${RABBITMQ_PWD:-rabbitmq123}
export KEYSTONE_NEUTRON_PWD=${KEYSTONE_NEUTRON_PWD:-KeystoneNeutron123}
export MYSQL_NEUTRON_PWD=${MYSQL_NEUTRON_PWD:-MysqlNeutron123}

## ceph
export CEPH_PUBLIC_IP=${CEPH_PUBLIC_IP:-${API_IP}}
export CEPH_CLUSTER_IP=${CEPH_CLUSTER_IP:-${API_IP}}
export CEPH_FSID=${CEPH_FSID:-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}
export CEPH_OSD_DATA_DIR=${CEPH_OSD_DATA_DIR:-/var/lib/stackube/openstack/ceph_osd}

## cinder
export KEYSTONE_CINDER_PWD=${KEYSTONE_CINDER_PWD:-KeystoneCinder123}
export MYSQL_CINDER_PWD=${MYSQL_CINDER_PWD:-MysqlCinder123}

## kubernetes
export KEYSTONE_URL="https://${API_IP}:5001/v2.0"
export KEYSTONE_ADMIN_URL="https://${API_IP}:35358/v2.0"
export CLUSTER_CIDR="10.244.0.0/16"
export CLUSTER_GATEWAY="10.244.0.1"
export CONTAINER_CIDR="10.244.1.0/24"
export FRAKTI_VERSION="v1.0"


## log
logDir='/var/log/stackube/'
logFile="${logDir}/install.log-$(date '+%Y-%m-%d_%H-%M-%S')"
mkdir -p ${logDir} || exit 1


## start
echo "
API_IP=${API_IP}
NEUTRON_EXT_IF=${NEUTRON_EXT_IF}
KUBERNETES_API_IP=${KUBERNETES_API_IP}

MYSQL_ROOT_PWD=${MYSQL_ROOT_PWD}
MYSQL_KEYSTONE_PWD=${MYSQL_KEYSTONE_PWD}
KEYSTONE_ADMIN_PWD=${KEYSTONE_ADMIN_PWD}
RABBITMQ_PWD=${RABBITMQ_PWD}
KEYSTONE_NEUTRON_PWD=${KEYSTONE_NEUTRON_PWD}
MYSQL_NEUTRON_PWD=${MYSQL_NEUTRON_PWD}

CEPH_PUBLIC_IP=${CEPH_PUBLIC_IP}
CEPH_CLUSTER_IP=${CEPH_CLUSTER_IP}
CEPH_FSID=${CEPH_FSID}
CEPH_OSD_DATA_DIR=${CEPH_OSD_DATA_DIR}

KEYSTONE_CINDER_PWD=${KEYSTONE_CINDER_PWD}
MYSQL_CINDER_PWD=${MYSQL_CINDER_PWD}

KEYSTONE_URL=${KEYSTONE_URL}
KEYSTONE_ADMIN_URL=${KEYSTONE_ADMIN_URL}
CLUSTER_CIDR=${CLUSTER_CIDR}
CLUSTER_GATEWAY=${CLUSTER_GATEWAY}
CONTAINER_CIDR=${CONTAINER_CIDR}
FRAKTI_VERSION=${FRAKTI_VERSION}
" >> ${logFile}

echo -e "\n\n$(date '+%Y-%m-%d %H:%M:%S') install_docker" | tee -a ${logFile}
#{ install_docker || exit 1; } 2>&1 | tee -a ${logFile}

echo -e "\n\n$(date '+%Y-%m-%d %H:%M:%S') deploy_openstack_keystone" | tee -a ${logFile}
#{ deploy_openstack_keystone || exit 1; } 2>&1 | tee -a ${logFile}

echo -e "\n\n$(date '+%Y-%m-%d %H:%M:%S') deploy_openstack_neutron" | tee -a ${logFile}
#{ deploy_openstack_neutron || exit 1; } 2>&1 | tee -a ${logFile}

echo -e "\n\n$(date '+%Y-%m-%d %H:%M:%S') deploy_ceph" | tee -a ${logFile}
#{ deploy_ceph || exit 1; } 2>&1 | tee -a ${logFile}

echo -e "\n\n$(date '+%Y-%m-%d %H:%M:%S') deploy_openstack_cinder" | tee -a ${logFile}
{ deploy_openstack_cinder || exit 1; } 2>&1 | tee -a ${logFile}

echo -e "\n\n$(date '+%Y-%m-%d %H:%M:%S') deploy_kubernetes" | tee -a ${logFile}
#{ deploy_kubernetes || exit 1; } 2>&1 | tee -a ${logFile}

echo -e "\n\n$(date '+%Y-%m-%d %H:%M:%S') All done." | tee -a ${logFile}


exit 0

