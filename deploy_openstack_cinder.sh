#!/bin/bash
#
# Dependencies:
#
# - ``API_IP``, ``RABBITMQ_PWD``
# - ``KEYSTONE_ADMIN_PWD``
# - ``KEYSTONE_CINDER_PWD``, ``MYSQL_CINDER_PWD``must be defined
#


programDir=`dirname $0`
programDir=$(readlink -f $programDir)
parentDir="$(dirname $programDir)"
programDirBaseName=$(basename $programDir)

set -x



## for OS_CACERT
source /etc/stackube/openstack/admin-openrc.sh  || exit 1


## register - Creating the Cinder service and endpoint
## v1
for IF in 'admin' 'internal' 'public'; do
    echo ${IF}
    docker exec -t stackube_kolla_toolbox /usr/bin/ansible localhost  -m kolla_keystone_service \
        -a "service_name=cinder
            service_type=volume
            description='Openstack Block Storage'
            endpoint_region=RegionOne
            url='https://${API_IP}:8777/v1/%(tenant_id)s'
            interface='${IF}'
            region_name=RegionOne
            auth='{{ openstack_keystone_auth }}'
            verify=False  " \
        -e "{'openstack_keystone_auth': {
               'auth_url': 'https://${API_IP}:35358/v3',
               'username': 'admin',
               'password': '${KEYSTONE_ADMIN_PWD}',
               'project_name': 'admin',
               'domain_name': 'default' } 
            }"  || exit 1
done

## v2
for VER in 'v2' ; do
    echo "$--- {VER} ---"
    for IF in 'admin' 'internal' 'public'; do
        echo ${IF}
        docker exec -t stackube_kolla_toolbox /usr/bin/ansible localhost  -m kolla_keystone_service \
            -a "service_name=cinder${VER}
                service_type=volume${VER}
                description='Openstack Block Storage'
                endpoint_region=RegionOne
                url='https://${API_IP}:8777/${VER}/%(tenant_id)s'
                interface='${IF}'
                region_name=RegionOne
                auth='{{ openstack_keystone_auth }}'
                verify=False  " \
            -e "{'openstack_keystone_auth': {
                   'auth_url': 'https://${API_IP}:35358/v3',
                   'username': 'admin',
                   'password': '${KEYSTONE_ADMIN_PWD}',
                   'project_name': 'admin',
                   'domain_name': 'default' } 
                }"  || exit 1
    done
done


## register -  Creating the Cinder project, user, and role
docker exec -t stackube_kolla_toolbox /usr/bin/ansible localhost  -m kolla_keystone_user \
    -a "project=service
        user=cinder
        password=${KEYSTONE_CINDER_PWD}
        role=admin
        region_name=RegionOne
        auth='{{ openstack_keystone_auth }}'
        verify=False  " \
    -e "{'openstack_keystone_auth': {
           'auth_url': 'https://${API_IP}:35358/v3',
           'username': 'admin',
           'password': '${KEYSTONE_ADMIN_PWD}',
           'project_name': 'admin',
           'domain_name': 'default' } 
        }"  || exit 1



# bootstrap - Creating Cinder database
docker exec -t stackube_kolla_toolbox /usr/bin/ansible localhost   -m mysql_db \
    -a "login_host=${API_IP}
        login_port=3306
        login_user=root
        login_password=${MYSQL_ROOT_PWD}
        name=cinder" || exit 1

# bootstrap - Creating Cinder database user and setting permissions
docker exec -t stackube_kolla_toolbox /usr/bin/ansible localhost   -m mysql_user \
    -a "login_host=${API_IP}
        login_port=3306
        login_user=root
        login_password=${MYSQL_ROOT_PWD}
        name=cinder
        password=${MYSQL_CINDER_PWD}
        host=%
        priv='cinder.*:ALL'
        append_privs=yes" || exit 1



# bootstrap_service - Running Cinder bootstrap container
sed -i "s/__THE_WORK_IP__/${API_IP}/g" /etc/stackube/openstack/cinder-api/cinder.conf || exit 1
sed -i "s/__CINDER_KEYSTONE_PWD__/${KEYSTONE_CINDER_PWD}/g" /etc/stackube/openstack/cinder-api/cinder.conf || exit 1
sed -i "s/__MYSQL_CINDER_PWD__/${MYSQL_CINDER_PWD}/g" /etc/stackube/openstack/cinder-api/cinder.conf || exit 1
sed -i "s/__RABBITMQ_PWD__/${RABBITMQ_PWD}/g" /etc/stackube/openstack/cinder-api/cinder.conf || exit 1

cp -f ${OS_CACERT} /etc/stackube/openstack/cinder-api/haproxy-ca.crt || exit 1

docker run -it --net host  \
    --name stackube_bootstrap_cinder  \
    -v /etc/stackube/openstack/cinder-api/:/var/lib/kolla/config_files/:ro  \
    -v /var/log/stackube/openstack:/var/log/kolla/:rw  \
    -e "KOLLA_BOOTSTRAP="  \
    -e "KOLLA_CONFIG_STRATEGY=COPY_ALWAYS" \
    kolla/centos-binary-cinder-api:4.0.0 || exit 1

sleep 2
docker rm stackube_bootstrap_cinder



## start_container - cinder-api
docker run -d  --net host  \
    --name stackube_cinder_api  \
    -v /etc/stackube/openstack/cinder-api/:/var/lib/kolla/config_files/:ro  \
    -v /var/log/stackube/openstack:/var/log/kolla/:rw  \
    \
    -e "KOLLA_SERVICE_NAME=cinder-api"  \
    -e "KOLLA_CONFIG_STRATEGY=COPY_ALWAYS" \
    \
    --restart unless-stopped \
    kolla/centos-binary-cinder-api:4.0.0 || exit 1




## start_container - cinder-scheduler
cp -f /etc/stackube/openstack/cinder-api/cinder.conf  /etc/stackube/openstack/cinder-scheduler/  || exit 1

docker run -d  --net host  \
    --name stackube_cinder_scheduler  \
    -v /etc/stackube/openstack/cinder-scheduler/:/var/lib/kolla/config_files/:ro  \
    -v /var/log/stackube/openstack:/var/log/kolla/:rw  \
    \
    -e "KOLLA_SERVICE_NAME=cinder-scheduler"  \
    -e "KOLLA_CONFIG_STRATEGY=COPY_ALWAYS" \
    \
    --restart unless-stopped \
    kolla/centos-binary-cinder-scheduler:4.0.0 || exit 1




## create osd pool for cinder volume service
docker exec -it stackube_ceph_mon ceph osd pool create cinder 64 64 || exit 1
docker exec -it stackube_ceph_mon ceph auth get-or-create client.cinder mon 'allow r' \
                 osd 'allow class-read object_prefix rbd_children, allow rwx pool=cinder' || exit 1
docker exec -it stackube_ceph_mon /bin/bash -c 'ceph auth get-or-create client.cinder | tee /etc/ceph/ceph.client.cinder.keyring' || exit 1

## start_container - cinder-volume
cp -f /var/lib/stackube/openstack/ceph_mon_config/{ceph.conf,ceph.client.cinder.keyring}  /etc/stackube/openstack/cinder-volume/  || exit 1
cp -f /etc/stackube/openstack/cinder-api/cinder.conf  /etc/stackube/openstack/cinder-volume/  || exit 1

docker run -d  --net host  \
    --name stackube_cinder_volume  \
    -v /etc/stackube/openstack/cinder-volume/:/var/lib/kolla/config_files/:ro  \
    -v /var/log/stackube/openstack:/var/log/kolla/:rw  \
    -v /run/:/run/:shared  \
    -v /dev/:/dev/:rw  \
    \
    -e "KOLLA_SERVICE_NAME=cinder-volume"  \
    -e "KOLLA_CONFIG_STRATEGY=COPY_ALWAYS" \
    \
    --restart unless-stopped \
    --privileged  \
    kolla/centos-binary-cinder-volume:4.0.0 || exit 1





## host config
cp -f /var/lib/stackube/openstack/ceph_mon_config/ceph.client.cinder.keyring /etc/ceph/ || exit 1

## check
rbd -p cinder --id cinder --keyring=/etc/ceph/ceph.client.cinder.keyring ls || exit 1
openstack volume service list || exit 1


exit 0
