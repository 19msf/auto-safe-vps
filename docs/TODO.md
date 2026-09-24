# 待办 / 设计权衡

## WireGuard（暂不自动化的原因）
经调研（参考 oneuptime/arillso/tangramvision 等 ansible role），WireGuard 自动化通用做法存在以下问题，对「3 台 VPS 一键加固」场景反而增加风险：

1. **拓扑歧义**：是 hub-and-spoke（一台中心 + 客户端）、full-mesh（互联）还是仅作为远程管理通道？三种拓扑的 peer 配置、AllowedIPs、路由表完全不同。
2. **客户端密钥管理**：服务端不应保存客户端私钥；目前主流的 ansible role 要么生成后留在控制机本地，要么需要手动分发。这与「无人值守一键执行」目标冲突。
3. **路由 / NAT 副作用**：开启 `wg-quick` 默认会改 ip route、iptables MASQUERADE，可能影响业务流量与 UFW 规则。

### 推荐手动方案
按官方 https://www.wireguard.com/quickstart/：
```bash
sudo apt install wireguard
umask 077; wg genkey | tee privatekey | wg pubkey > publickey
# 编辑 /etc/wireguard/wg0.conf，server / peer 各自一份
sudo systemctl enable --now wg-quick@wg0
sudo ufw allow 51820/udp
```
等拓扑确定后，可以再把这部分单独抽成一个 role。

## 其他备注
- **Cloudflare 已作为可选 role 集成**：默认关闭；启用后由 `cloudflare_ufw` role 将指定端口锁定到 Cloudflare 官方 IP 段。接入雷池或其他反代时，仍需单独配置可信代理和真实访客 IP 头。
- **三网优化**：保留主机自带的设置；本剧本只开启 BBR + fq，不会做额外 sysctl 调优。
- **Ubuntu Pro**：按需求未集成。
