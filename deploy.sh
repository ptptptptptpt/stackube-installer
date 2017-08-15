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
        yum install docker-engine-1.12.6 -y || return 1
        #sed -i 's|ExecStart=.*|ExecStart=/usr/bin/dockerd  --storage-opt dm.mountopt=nodiscard --storage-opt dm.blkdiscard=false|g' /usr/lib/systemd/system/docker.service
        sed -i 's|ExecStart=.*|ExecStart=/usr/bin/dockerd  -s overlay |g' /usr/lib/systemd/system/docker.service
        systemctl daemon-reload  || return 1
        systemctl enable docker || return 1
        systemctl start  docker || return 1
    fi

    docker info &> /dev/null || return 1
}


function deploy_openstack {
    echo "Deploying OpenStack Keystone..."
    /bin/bash ${programDir}/deploy_openstack_keystone.sh
    if [ "$?" == "0" ]; then
        echo -e "\nOpenStack Keystone deployed successfully!\n"
    else
        echo -e "\nOpenStack Keystone deployed failed!\n"
        return 1
    fi

    echo "Deploying OpenStack Neutron..."
    /bin/bash ${programDir}/deploy_openstack_neutron.sh
    if [ "$?" == "0" ]; then
        echo -e "\nOpenStack Neutron deployed successfully!\n"
    else
        echo -e "\nOpenStack Neutron deployed failed!\n"
        return 1
    fi

    sleep 10

    yum install centos-release-openstack-ocata.noarch -y  || return 1
    yum install python-openstackclient openvswitch -y  || return 1

    ovs-vsctl show

    source /etc/stackube/openstack/admin-openrc.sh  || return 1
    openstack network create --external  br-ex  || return 1
    openstack network list
    openstack subnet list

}


function deploy_kubernetes {
    echo "Deploying Kubernetes..."
    /bin/bash ${programDir}/deploy_kubernetes.sh
    if [ "$?" == "0" ]; then
        echo -e "\nKubernetes deployed successfully!\n"
    else
        echo -e "\Kubernetes deployed failed!\n"
        return 1
    fi

}






######################################
######################################

[ "$1" ] || { usage; exit 1; }
[ -f "$1" ] || { echo "Error: $1 not exists or not a file!"; exit 1; }

source $(readlink -f $1) || { echo "'source $(readlink -f $1)' failed!"; exit 1; }

[ "${API_IP}" ] || { echo "Error: API_IP not defined!"; exit 1; }
[ "${KUBERNETES_API_IP}" ] || { echo "Error: KUBERNETES_API_IP not defined!"; exit 1; }
[ "${NEUTRON_EXT_IF}" ] || { echo "Error: NEUTRON_EXT_IF not defined!"; exit 1; }



# TODO：判断发行版，只支持 centos 7


date

set -x

export API_IP
export NEUTRON_EXT_IF
export KUBERNETES_API_IP

export MYSQL_ROOT_PWD=${MYSQL_ROOT_PWD:-MysqlRoot123}
export MYSQL_KEYSTONE_PWD=${MYSQL_KEYSTONE_PWD:-MysqlKeystone123}
export KEYSTONE_ADMIN_PWD=${KEYSTONE_ADMIN_PWD:-KeystoneAdmin123}
export RABBITMQ_PWD=${RABBITMQ_PWD:-rabbitmq123}
export KEYSTONE_NEUTRON_PWD=${KEYSTONE_NEUTRON_PWD:-KeystoneNeutron123}
export MYSQL_NEUTRON_PWD=${MYSQL_NEUTRON_PWD:-MysqlNeutron123}

export KEYSTONE_URL="https://${API_IP}:5001/v2.0"
export KEYSTONE_ADMIN_URL="https://${API_IP}:35358/v2.0"
export CLUSTER_CIDR="10.244.0.0/16"
export CLUSTER_GATEWAY="10.244.0.1"
export CONTAINER_CIDR="10.244.1.0/24"
export FRAKTI_VERSION="v1.0"


install_docker || exit 1

deploy_openstack || exit 1

deploy_kubernetes || exit 1

date


exit 0

