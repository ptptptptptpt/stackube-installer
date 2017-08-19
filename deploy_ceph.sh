#!/bin/bash
#
# Dependencies:
#
# - ``CEPH_PUBLIC_IP``, ``CEPH_CLUSTER_IP``,
# - ``CEPH_FSID``,
# - ``CEPH_OSD_DATA_DIR``   must be defined
#

programDir=`dirname $0`
programDir=$(readlink -f $programDir)
parentDir="$(dirname $programDir)"
programDirBaseName=$(basename $programDir)

set -x

## ceph-mon
sed -i "s/__FSID__/${CEPH_FSID}/g" /etc/stackube/openstack/ceph-mon/ceph.conf || exit 1
sed -i "s/__PUBLIC_IP__/${CEPH_PUBLIC_IP}/g" /etc/stackube/openstack/ceph-mon/ceph.conf || exit 1
sed -i "s/__PUBLIC_IP__/${CEPH_PUBLIC_IP}/g" /etc/stackube/openstack/ceph-mon/config.json || exit 1

mkdir -p /var/lib/stackube/openstack/ceph_mon_config  && \
mkdir -p /var/lib/stackube/openstack/ceph_mon  && \
docker run -it --net host  \
    --name stackube_bootstrap_ceph_mon  \
    -v /etc/stackube/openstack/ceph-mon/:/var/lib/kolla/config_files/:ro  \
    -v /var/log/stackube/openstack:/var/log/kolla/:rw  \
    -v /var/lib/stackube/openstack/ceph_mon_config:/etc/ceph/:rw  \
    -v /var/lib/stackube/openstack/ceph_mon:/var/lib/ceph/:rw  \
    \
    -e "KOLLA_BOOTSTRAP="  \
    -e "KOLLA_CONFIG_STRATEGY=COPY_ALWAYS" \
    -e "MON_IP=${CEPH_PUBLIC_IP}" \
    -e "HOSTNAME=${CEPH_PUBLIC_IP}" \
    kolla/centos-binary-ceph-mon:4.0.0 || exit 1

docker rm stackube_bootstrap_ceph_mon

docker run -d  --net host  \
    --name stackube_ceph_mon  \
    -v /etc/stackube/openstack/ceph-mon/:/var/lib/kolla/config_files/:ro  \
    -v /var/log/stackube/openstack:/var/log/kolla/:rw  \
    -v /var/lib/stackube/openstack/ceph_mon_config:/etc/ceph/:rw  \
    -v /var/lib/stackube/openstack/ceph_mon:/var/lib/ceph/:rw  \
    \
    -e "KOLLA_SERVICE_NAME=ceph-mon"  \
    -e "HOSTNAME=${CEPH_PUBLIC_IP}"  \
    -e "KOLLA_CONFIG_STRATEGY=COPY_ALWAYS" \
    \
    --restart unless-stopped \
    kolla/centos-binary-ceph-mon:4.0.0

sleep 5

docker exec -it stackube_ceph_mon ceph -s


## ceph-osd
cp --remove-destination /var/lib/stackube/openstack/ceph_mon_config/{ceph.client.admin.keyring,ceph.conf} /etc/stackube/openstack/ceph-osd/  || exit 1
sed -i "s/__PUBLIC_IP__/${CEPH_PUBLIC_IP}/g" /etc/stackube/openstack/ceph-osd/add_osd.sh || exit 1
sed -i "s/__PUBLIC_IP__/${CEPH_PUBLIC_IP}/g" /etc/stackube/openstack/ceph-osd/config.json || exit 1
sed -i "s/__CLUSTER_IP__/${CEPH_CLUSTER_IP}/g" /etc/stackube/openstack/ceph-osd/config.json || exit 1

mkdir -p ${CEPH_OSD_DATA_DIR} || exit 1

docker run -it --net host  \
    --name stackube_bootstrap_ceph_osd  \
    -v /etc/stackube/openstack/ceph-osd/:/var/lib/kolla/config_files/:ro  \
    -v /var/log/stackube/openstack:/var/log/kolla/:rw  \
    -v ${CEPH_OSD_DATA_DIR}:/var/lib/ceph/:rw  \
    \
    kolla/centos-binary-ceph-osd:4.0.0 /bin/bash /var/lib/kolla/config_files/add_osd.sh  || exit 1

docker rm stackube_bootstrap_ceph_osd

theOsd=`ls ${CEPH_OSD_DATA_DIR}/osd/ | grep -- 'ceph-' | head -n 1`
[ "${theOsd}" ] || exit 1
osdId=`echo $theOsd | awk -F\- '{print $NF}'`
[ "${osdId}" ] || exit 1

docker run -d  --net host  \
    --name stackube_ceph_osd_${osdId}  \
    -v /etc/stackube/openstack/ceph-osd/:/var/lib/kolla/config_files/:ro  \
    -v /var/log/stackube/openstack:/var/log/kolla/:rw  \
    -v ${CEPH_OSD_DATA_DIR}:/var/lib/ceph/:rw  \
    \
    -e "KOLLA_SERVICE_NAME=ceph-osd"  \
    -e "KOLLA_CONFIG_STRATEGY=COPY_ALWAYS" \
    -e "OSD_ID=${osdId}"  \
    -e "JOURNAL_PARTITION=/var/lib/ceph/osd/ceph-${osdId}/journal" \
    \
    --restart unless-stopped \
    kolla/centos-binary-ceph-osd:4.0.0 || exit 1

sleep 5

docker exec -it stackube_ceph_mon ceph osd crush tree || exit 1


## host config
yum install ceph -y  || exit 1
cp -f /var/lib/stackube/openstack/ceph_mon_config/* /etc/ceph/ || exit 1
ceph -s || exit 1



exit 0
