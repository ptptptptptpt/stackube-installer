# Stackube 多节点部署（无HA）

### 控制节点（1台）
- 要求
    - 1个公网网卡，带公网ip
    - 1个私网网卡，mtu >= 1600，与其它节点私网ip互通

### 计算节点（至少1台）
- 要求
    - 1个私网网卡，mtu >= 1600，与其它节点私网ip互通

### 网络节点（1台）
- 要求
    - 1个公网网卡，不带公网ip，作为 neutron external interface
    - 1个私网网卡，mtu >= 1600，与其它节点私网ip互通

### 存储节点（至少1台）
- 要求
    - 1个私网网卡，mtu >= 1600，与其它节点私网ip互通

### 公网ip池
- 要求
    - 若干数量的公网ip
    
