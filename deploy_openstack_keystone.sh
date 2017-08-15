#!/bin/bash
#
# Dependencies:
#
# - ``API_IP``, ``MYSQL_ROOT_PWD``
# - ``MYSQL_KEYSTONE_PWD``, ``KEYSTONE_ADMIN_PWD``
# - ``RABBITMQ_PWD`` must be defined
#

programDir=`dirname $0`
programDir=$(readlink -f $programDir)
parentDir="$(dirname $programDir)"
programDirBaseName=$(basename $programDir)

set -x

## certificates
DATA_DIR='/etc/stackube/openstack/certificates'
HOST_IP=${API_IP}
SERVICE_HOST=${API_IP}
SERVICE_IP=${API_IP}

source ${programDir}/lib_tls.sh || exit 1
mkdir -p ${DATA_DIR} || exit 1
init_CA || exit 1
init_cert || exit 1



## config files
mkdir -p /etc/stackube/openstack  || exit 1
cp -a ${programDir}/openstack_config_files/* /etc/stackube/openstack/  || exit 1
mkdir -p /var/log/stackube/openstack || exit 1
chmod 777 /var/log/stackube/openstack || exit 1



## haproxy for tls
sed -i "s/__THE_WORK_IP__/${API_IP}/g" /etc/stackube/openstack/haproxy/haproxy.cfg || exit 1
cat ${STACKUBE_CERT} > /etc/stackube/openstack/haproxy/haproxy.pem || exit 1
docker run -d  --net host  \
    --name stackube_haproxy  \
    -v /etc/stackube/openstack/haproxy/:/var/lib/kolla/config_files/:ro  \
    -v /var/log/stackube/openstack:/var/log/kolla/:rw  \
    \
    -e "KOLLA_SERVICE_NAME=haproxy"  \
    -e "KOLLA_CONFIG_STRATEGY=COPY_ALWAYS" \
    \
    --restart unless-stopped \
    --privileged  \
    kolla/centos-binary-haproxy:4.0.0  || exit 1


## mariadb
mkdir -p /var/lib/stackube/openstack/mariadb  && \
docker run -d \
    --name stackube_mariadb \
    --net host  \
    -e MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PWD} \
    -v /var/lib/stackube/openstack/mariadb:/var/lib/mysql \
    --restart unless-stopped \
    mariadb:5.5 || exit 1


## rabbitmq 
mkdir -p /var/lib/stackube/openstack/rabbitmq  && \
docker run -d \
    --name stackube_rabbitmq \
    --net host  \
    -v /var/lib/stackube/openstack/rabbitmq:/var/lib/rabbitmq \
    --restart unless-stopped \
    rabbitmq:3.6 || exit 1

sleep 5
for i in 1 2 3 4 5; do
    docker exec -it stackube_rabbitmq rabbitmqctl status && break
    sleep $i
done
docker exec -it stackube_rabbitmq rabbitmqctl add_user openstack ${RABBITMQ_PWD}  || exit 1
docker exec -it stackube_rabbitmq rabbitmqctl set_permissions openstack ".*" ".*" ".*"  || exit 1


## kolla-toolbox
docker run -d  --net host  \
    --name stackube_kolla_toolbox  \
    -v /run/:/run/:shared  \
    -v /dev/:/dev/:rw  \
    -v /etc/stackube/openstack/kolla-toolbox/:/var/lib/kolla/config_files/:ro  \
    -v /var/log/stackube/openstack:/var/log/kolla/:rw  \
    -e "KOLLA_SERVICE_NAME=kolla-toolbox"  \
    -e "ANSIBLE_LIBRARY=/usr/share/ansible"  \
    -e "ANSIBLE_NOCOLOR=1"  \
    -e "KOLLA_CONFIG_STRATEGY=COPY_ALWAYS" \
    --restart unless-stopped  \
    --privileged  \
    kolla/centos-binary-kolla-toolbox:4.0.0  || exit 1

sleep 10

## keystone
docker exec -it stackube_kolla_toolbox /usr/bin/ansible localhost -m mysql_db  \
    -a "login_host=${API_IP}
        login_port=3306
        login_user=root
        login_password=${MYSQL_ROOT_PWD}
        name=keystone"  || exit 1

docker exec -it stackube_kolla_toolbox /usr/bin/ansible localhost -m mysql_user  \
    -a "login_host=${API_IP}
        login_port=3306
        login_user=root
        login_password=${MYSQL_ROOT_PWD}
        name=keystone
        password=${MYSQL_KEYSTONE_PWD}
        host=%
        priv=keystone.*:ALL
        append_privs=yes "  || exit 1

sed -i "s/__THE_WORK_IP__/${API_IP}/g" /etc/stackube/openstack/keystone/keystone.conf
sed -i "s/__MYSQL_KWYSTONE_PWD__/${MYSQL_KEYSTONE_PWD}/g" /etc/stackube/openstack/keystone/keystone.conf
sed -i "s/__THE_WORK_IP__/${API_IP}/g" /etc/stackube/openstack/keystone/wsgi-keystone.conf 

# bootstrap_service
docker run -it --net host  \
    --name stackube_bootstrap_keystone  \
    -v /etc/stackube/openstack/keystone/:/var/lib/kolla/config_files/:ro  \
    -v /var/log/stackube/openstack:/var/log/kolla/:rw  \
    -e "KOLLA_BOOTSTRAP="  \
    -e "KOLLA_CONFIG_STRATEGY=COPY_ALWAYS" \
    kolla/centos-binary-keystone:4.0.0  || exit 1

docker rm stackube_bootstrap_keystone

docker run -d  --net host  \
    --name stackube_keystone  \
    -v /etc/stackube/openstack/keystone/:/var/lib/kolla/config_files/:ro  \
    -v /var/log/stackube/openstack:/var/log/kolla/:rw  \
    -e "KOLLA_SERVICE_NAME=keystone"  \
    -e "KOLLA_CONFIG_STRATEGY=COPY_ALWAYS" \
    --restart unless-stopped \
    kolla/centos-binary-keystone:4.0.0  || exit 1

sleep 10

# register
docker exec -it stackube_keystone kolla_keystone_bootstrap admin ${KEYSTONE_ADMIN_PWD} admin admin \
    https://${API_IP}:35358/v3 \
    https://${API_IP}:5001/v3 \
    https://${API_IP}:5001/v3 \
    RegionOne  || exit 1

docker exec -it stackube_kolla_toolbox /usr/bin/ansible localhost -m os_keystone_role  -a "name=_member_  auth='{{ openstack_keystone_auth }}' verify=False"  \
    -e "{'openstack_keystone_auth': {
           'auth_url': 'https://${API_IP}:35358/v3',
           'username': 'admin',
           'password': '${KEYSTONE_ADMIN_PWD}',
           'project_name': 'admin',
           'domain_name': 'default' } 
        }" || exit 1


cat > /etc/stackube/openstack/admin-openrc.sh << EOF
export OS_PROJECT_DOMAIN_NAME=default
export OS_USER_DOMAIN_NAME=default
export OS_PROJECT_NAME=admin
export OS_TENANT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=${KEYSTONE_ADMIN_PWD}
export OS_AUTH_URL=https://${API_IP}:35358/v3
export OS_INTERFACE=internal
export OS_IDENTITY_API_VERSION=3
export OS_CACERT=${INT_CA_DIR}/ca-chain.pem
EOF


exit 0

