#!/bin/bash
#

programDir=`dirname $0`
programDir=$(readlink -f $programDir)
parentDir="$(dirname $programDir)"
programDirBaseName=$(basename $programDir)

set -x


## remove docker containers
stackubeCephConstaners=`docker ps -a | awk '{print $NF}' | grep '^stackube_ceph_' `
if [ "${stackubeCephConstaners}" ]; then
    docker kill -s 9 $stackubeCephConstaners
    docker rm -f $stackubeCephConstaners || exit 1
fi

## rm dirs
rm -fr /etc/stackube/openstack/ceph-*  /var/log/stackube/openstack/ceph  /var/lib/stackube/openstack/ceph_*  || exit 1



exit 0

