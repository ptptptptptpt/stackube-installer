#Stackube 多节点部署（无HA）

###控制节点（1台）
- 部署内容
    - k8s master
    - openstack 控制组件（mysql、rabbitmq、keystone、neutron-server、cinder）
    - ceph-mon
- 要求
    - 1个公网网卡，带公网ip，用于 k8s api-server
        - 每个 tenant 的 dns 服务以容器形式运行在其 namespace 中，访问不到集群私网，只能通过公网访问 k8s api-server
        - 用户也要访问 api-server
    - 1个私网网卡，mtu >= 1600，与其它节点私网ip互通
        - 用于 k8s api-server （接受来自计算节点 kubelet 的访问）
        - 承载 openstack（keystone/neutron/cinder）、ceph 控制面流量

###计算节点（至少1台）
- 部署内容
    - qemu，libvirtd，hyperd，frakti
    - kubelet
    - openvswitch，neutron-openvswitch-agent
- 要求
    - 1个私网网卡，mtu >= 1600，与其它节点私网ip互通
        - 承载 neutron、ceph 流量（包括控制面和数据面） 

###网络节点（1台）
- 部署内容
    - openvswitch，neutron-openvswitch-agent，neutron-l3-agent，neutron-lbaas-agent，neutron-dhcp-agent
- 要求
    - 1个公网网卡，不带公网ip，作为 neutron external interface
        - 该网卡会被 add 到一个名为 br-ex 的 ovs 网桥
    - 1个私网网卡，mtu >= 1600，与其它节点私网ip互通
        - 承载 neutron 流量（包括控制面和数据面） 

###存储节点（至少1台）
- 部署内容
    - openvswitch，neutron-openvswitch-agent，neutron-l3-agent，neutron-lbaas-agent，neutron-dhcp-agent
- 要求
    - 1个私网网卡，mtu >= 1600，与其它节点私网ip互通
        - 承载 ceph 流量（包括控制面和数据面）
