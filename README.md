# ssh-tunnel-proxy

一条命令，让任何 Linux 设备通过一台中继服务器实现：

- **访问外网** — SOCKS5 代理 + sshuttle 透明代理
- **从外网访问本机** — 反向 SSH 隧道

适用于：DGX Spark、树莓派、工控机、内网服务器等任何 Linux 设备。

## 架构

```
┌──────────────┐   SSH (出站)    ┌───────────────┐   ┌───────────┐
│  你的 Linux   │ ──────────────→ │   中继服务器    │ ←─│ 其他设备   │
│  (内网/NAT)   │                │  (有公网 IP)   │   │ (笔记本等) │
└──────────────┘                └───────────────┘   └───────────┘
     ↑                                  │
     └── SOCKS5 / sshuttle 隧道 ────────┘ → 访问外网
```

## 快速安装

### 前提

- 本地机器：Linux，有 sudo 权限
- 中继服务器：有公网 IP，SSH 可达（建议香港/海外）
- 本地机器能发起 SSH 出站连接到中继服务器

```bash
# 方式一：本地安装（推荐）
sudo bash install.sh --server root@你的服务器IP

# 方式二：远程安装（只需输入一次中继服务器密码）
curl -sSL https://raw.githubusercontent.com/evaworks/ssh-tunnel-proxy/main/install.sh | \
  bash -s -- --server root@你的服务器IP
```

### 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--server` | (必填) | 中继服务器地址，格式 `user@host` |
| `--tunnel-port` | `2222` | 反向隧道映射到中继服务器的端口 |
| `--socks5-port` | `1080` | 本地 SOCKS5 代理端口 |
| `--ssh-port` | `22` | 中继服务器 SSH 端口（非常规端口时使用） |
| `--only-reverse` | — | 仅部署反向隧道（跳过 SOCKS5） |
| `--only-socks5` | — | 仅部署 SOCKS5 代理（跳过反向隧道） |
| `--enable-sshuttle` | — | 自动启用 sshuttle 透明代理 |
| `--verbose` | — | 显示详细执行输出 |
| `--dry-run` | — | 仅预览要执行的操作 |

### 安装过程

| 步骤 | 动作 | 交互 |
|------|------|------|
| 1 | 预检：系统、端口、网络连通性 | 自动 |
| 2 | 安装 autossh、sshuttle | 自动（sudo） |
| 3 | 生成 ed25519 SSH 密钥（如无） | 自动 |
| 4 | 拷贝公钥到中继服务器 | **输入一次服务器密码** |
| 5 | 测试免密登录 | 自动 |
| 6 | 远程配置：GatewayPorts + 防火墙 | 自动免密，先备份 sshd_config，`sshd -t` 验证后再重启 |
| 7 | 本地配置：创建 systemd 服务 + 环境配置文件 | 自动 |
| 8 | 启动隧道 | 自动 |
| 9 | 验证服务状态 | 自动 |

## 使用

### 从其他设备 SSH 连接到本机

```bash
# 方式一：跳板登录
ssh -J root@中继IP 你的用户名@localhost -p 2222

# 方式二：使用 SSH config（安装时已生成）
ssh tunnel-proxy
```

### 本机通过代理访问外网

```bash
# SOCKS5 代理（应用级）
curl --socks5-hostname 127.0.0.1:1080 https://www.google.com

# 系统全局使用
export ALL_PROXY=socks5h://127.0.0.1:1080

# sshuttle 透明代理（全流量 TCP）
sudo systemctl enable --now tunnel-sshuttle.service
```

### 服务管理

```bash
# 查看状态
sudo systemctl status tunnel-reverse      # 反向隧道
sudo systemctl status tunnel-socks5        # SOCKS5 代理
sudo systemctl status tunnel-sshuttle      # sshuttle 透明代理

# 启动/停止/重启
sudo systemctl start/stop/restart tunnel-reverse
sudo systemctl enable/disable tunnel-reverse

# 查看日志
sudo journalctl -u tunnel-reverse -f
sudo journalctl -u tunnel-socks5 -f
sudo journalctl -u tunnel-sshuttle -f
```

### 修改端口等配置

```bash
# 方式一：编辑配置文件，然后重启服务
sudo vim /etc/ssh-tunnel-proxy/tunnel.conf
sudo systemctl restart tunnel-reverse
sudo systemctl restart tunnel-socks5

# 方式二：直接重新运行安装脚本（自动检测重部署并重启服务）
./install.sh --server root@1.2.3.4 --tunnel-port 8888
```

## 卸载

```bash
# 方式一：本地卸载（推荐）
sudo bash uninstall.sh

# 方式二：远程卸载
curl -sSL https://raw.githubusercontent.com/evaworks/ssh-tunnel-proxy/main/uninstall.sh | bash
```

卸载脚本会自动清理中继服务器（还原 GatewayPorts、关闭防火墙端口、重启 SSH 服务）。如果自动清理失败，再手动处理：

```bash
ssh root@中继服务器IP
sudo sed -i '/^GatewayPorts yes/d' /etc/ssh/sshd_config
sudo systemctl restart sshd
```

## 技术细节

| 组件 | 原理 | 守护方式 |
|------|------|---------|
| 反向隧道 | `ssh -R` 将本地 22 → 中继服务器 2222 | systemd + autossh（断线重连） |
| SOCKS5 代理 | `ssh -D` 动态端口转发 | systemd + autossh（断线重连） |
| 透明代理 | SSH 隧道 + iptables 规则 | systemd + sshuttle |
| 配置持久化 | 环境文件 `/etc/ssh-tunnel-proxy/tunnel.conf` | 修改后重启服务即可生效 |

### 安全措施

- sshd_config 修改前备份至 `.bak.ssh-tunnel-proxy`
- 重启 sshd 前执行 `sshd -t` 验证配置
- 配置校验失败自动回滚备份
- 所有服务以普通用户身份运行（`User=` 指令）
- sshuttle 使用 PID 文件管理进程

## License

MIT
