# Relay Throughput Tune

面向 Debian / Ubuntu 应用层中转服务器的 TCP 吞吐调优脚本。适合 Xray、sing-box、HAProxy 等场景；它会根据带宽、RTT、内存和 CPU 核数生成较保守的 BBR + FQ 配置，并保留回滚备份。

> 不能保证“必定跑满带宽”。CPU、网卡队列、IRQ、宿主机超售、运营商路径与应用本身都可能成为瓶颈。

## 一键使用

```bash
curl -fsSL https://raw.githubusercontent.com/SYNY0/relay-throughput-tune/main/relay-throughput-tune.sh -o /tmp/relay-throughput-tune.sh && bash /tmp/relay-throughput-tune.sh
```

脚本会交互询问服务器带宽与典型 RTT，写入 `/etc/sysctl.d/zz-relay-throughput.conf`，并在 `/root/relay-tune-backup-时间戳/` 保存备份和 `rollback.sh`。

## 配置模式

默认是 `throughput`，适合少量到中等数量的跨境大流量连接。

```bash
# 更保守的内存上限
PROFILE=balanced bash relay-throughput-tune.sh

# 更适合大量并发连接的内存上限
PROFILE=concurrency bash relay-throughput-tune.sh
```

只有在 `/proc/net/softnet_stat` 的 `time_squeeze` 或丢包计数持续增长、且确认软中断是瓶颈时，才建议使用激进软中断参数：

```bash
AGGRESSIVE_SOFTIRQ=1 bash relay-throughput-tune.sh
```

## 部署后检查

重启后确认：

```bash
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
tc qdisc show dev "$(ip route show default | awk '/default/ {print $5; exit}')"
```

预期拥塞控制为 `bbr`，默认队列规则为 `fq`。高并发场景还应单独检查应用的 `LimitNOFILE`、监听 backlog、CPU 使用率、软中断与重传率。

## 支持范围

- Debian 11/12/13、Ubuntu 22.04/24.04 等使用 systemd/procps 的主机
- KVM VPS 或物理机
- 不保证在 OpenVZ/LXC 等受限容器中具有修改 sysctl 的权限

## 回滚

执行脚本输出的备份目录中的 `rollback.sh`，然后重启服务器。

## 许可证

MIT

## Automatic detection

The default command identifies the public server location and tests usable download bandwidth twice against Cloudflare. If an installed `speedtest` (Ookla CLI) or `speedtest-cli` command is available, it is tested as a second source; the default `BANDWIDTH_POLICY=peak` selects the highest successful result.

The result is an Internet-egress estimate, not a guarantee for every relay path. For target-specific tuning, use a real destination as the RTT probe or override the value:

```bash
RELAY_HOST=your-relay-destination.example bash /tmp/relay-throughput-tune.sh
# or
BW_MBPS=1000 RTT_MS=150 bash /tmp/relay-throughput-tune.sh
```

Use `BANDWIDTH_POLICY=average` or `BANDWIDTH_POLICY=conservative` when a less optimistic bandwidth estimate is preferred. Set `AUTO_DETECT=0` to disable automatic public-IP/location and bandwidth detection.
