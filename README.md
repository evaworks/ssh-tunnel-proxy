# ssh-tunnel-proxy

一条命令，让任何 Linux / Windows 设备通过一台中继服务器实现：

- **访问外网** — SOCKS5 代理
- **从外网访问本机** — 反向 SSH 隧道

适用于：DGX Spark、树莓派、工控机、Windows PC、内网服务器等任何设备。

## 架构

```
┌─────────────────┐   SSH (出站)    ┌───────────────┐   ┌───────────┐
│  你的设备        │ ──────────────→ │   中继服务器    │ ←─│ 其他设备   │
│  Linux / Windows │                │  (有公网 IP)   │   │ (笔记本等) │
│  (内网/NAT)      │                └───────────────┘   └───────────┘
└─────────────────┘
     ↑
      └── SOCKS5 隧道 ──────────────────────────→ 访问外网
```

## 快速安装

### 前提

- 中继服务器：有公网 IP，SSH 可达（建议香港/海外）
- 本机能发起 SSH 出站连接到中继服务器

### Linux

需要 sudo 权限。

```bash
# 方式一：本地安装（推荐）
sudo bash install.sh --server root@你的服务器IP

# 方式二：远程安装（只需输入一次中继服务器密码）
curl -sSL https://raw.githubusercontent.com/evaworks/ssh-tunnel-proxy/master/install.sh | \
  bash -s -- --server root@你的服务器IP
```

### Windows

需要管理员权限运行 PowerShell。

```powershell
# 管理员 PowerShell
Set-ExecutionPolicy RemoteSigned -Scope Process -Force
iwr -useb https://raw.githubusercontent.com/evaworks/ssh-tunnel-proxy/master/install.ps1 | iex
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
| 2 | 安装必要依赖（OpenSSH、NSSM） | 自动 |
| 3 | 生成 ed25519 SSH 密钥（如无） | 自动 |
| 4 | 拷贝公钥到中继服务器 | **输入一次服务器密码** |
| 5 | 测试免密登录 | 自动 |
| 6 | 远程配置：GatewayPorts + 防火墙 | 自动免密，先备份 sshd_config，`sshd -t` 验证后再重启 |
| 7 | 本地配置：创建服务（Linux: systemd / Windows: NSSM）+ 配置文件 | 自动 |
| 8 | 启动隧道并设置开机自启 | 自动 |
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

# 可选：sshuttle 透明代理（全流量 TCP，需 --enable-sshuttle 安装）
sudo systemctl enable --now tunnel-sshuttle.service
```

### 服务管理

安装完成后所有隧道服务会自动启动并设置为开机自启，无需额外操作。

**Linux（systemd）：**

```bash
# 查看状态
sudo systemctl status tunnel-reverse      # 反向隧道
sudo systemctl status tunnel-socks5        # SOCKS5 代理
sudo systemctl status tunnel-sshuttle      # sshuttle 透明代理（如已安装）

# 一键临时关闭/启动/重启（两个服务一起操作）
sudo systemctl stop tunnel-reverse tunnel-socks5
sudo systemctl start tunnel-reverse tunnel-socks5
sudo systemctl restart tunnel-reverse tunnel-socks5

# 关闭并取消开机自启
sudo systemctl disable --now tunnel-reverse tunnel-socks5
# 重新启用并立即启动
sudo systemctl enable --now tunnel-reverse tunnel-socks5

# 查看日志
sudo journalctl -u tunnel-reverse -f
sudo journalctl -u tunnel-socks5 -f
```

**Windows（NSSM）：**

```powershell
# 设置 nssm 命令别名（一次设置，后续可直接用 nssm）
$env:Path += ";C:\Program Files\nssm"

# 查看状态
nssm status ssh-tunnel-reverse
nssm status ssh-tunnel-socks5

# 一键临时关闭/启动/重启（两个服务一起操作）
nssm stop ssh-tunnel-reverse ssh-tunnel-socks5
nssm start ssh-tunnel-reverse ssh-tunnel-socks5
nssm restart ssh-tunnel-reverse ssh-tunnel-socks5

# 关闭并取消开机自启（改为手动启动）
nssm set ssh-tunnel-reverse Start SERVICE_DEMAND_START
nssm set ssh-tunnel-socks5 Start SERVICE_DEMAND_START
# 重新启用开机自启
nssm set ssh-tunnel-reverse Start SERVICE_AUTO_START
nssm set ssh-tunnel-socks5 Start SERVICE_AUTO_START

# 查看日志
Get-Content "$env:ProgramData\ssh-tunnel-proxy\reverse-stdout.log" -Tail 20
Get-Content "$env:ProgramData\ssh-tunnel-proxy\socks5-stdout.log" -Tail 20
```

### 修改端口等配置

**Linux：**

```bash
# 方式一：编辑配置文件，然后重启服务
sudo vim /etc/ssh-tunnel-proxy/tunnel.conf
sudo systemctl restart tunnel-reverse
sudo systemctl restart tunnel-socks5

# 方式二：直接重新运行安装脚本（自动检测重部署并重启服务）
./install.sh --server root@1.2.3.4 --tunnel-port 8888
```

**Windows：**

```powershell
# 重新运行安装脚本（自动检测重部署并重启服务）
.\install.ps1 -Server root@1.2.3.4 -TunnelPort 8888
```

## 卸载

### Linux

```bash
# 本地卸载（推荐）
sudo bash uninstall.sh

# 远程卸载
curl -sSL https://raw.githubusercontent.com/evaworks/ssh-tunnel-proxy/master/uninstall.sh | bash
```

### Windows

```powershell
# 管理员 PowerShell
iwr -useb https://raw.githubusercontent.com/evaworks/ssh-tunnel-proxy/master/uninstall.ps1 | iex
```

### 手动清理中继服务器

如果自动清理失败：

```bash
ssh root@中继服务器IP
sudo sed -i '/^GatewayPorts yes/d' /etc/ssh/sshd_config
sudo systemctl restart sshd
```

## 技术细节

| 组件 | 原理 | Linux 守护 | Windows 守护 |
|------|------|------------|--------------|
| 反向隧道 | `ssh -R` 将本地 22 → 中继服务器 2222 | systemd + SSH（断线重连） | NSSM + SSH（断线重连） |
| SOCKS5 代理 | `ssh -D` 动态端口转发 | systemd + SSH（断线重连） | NSSM + SSH（断线重连） |
| 透明代理 | SSH 隧道 + iptables 规则 | systemd + sshuttle（可选） | 不支持（无 iptables） |
| 配置持久化 | 配置文件 | `/etc/ssh-tunnel-proxy/tunnel.conf` | `%ProgramData%\ssh-tunnel-proxy\tunnel.json` |

### 安全措施

- sshd_config 修改前备份至 `.bak.ssh-tunnel-proxy`
- 重启 sshd 前执行 `sshd -t` 验证配置
- 配置校验失败自动回滚备份
- Linux: 服务以普通用户身份运行（`User=` 指令）
- Windows: 自动设置系统 SOCKS5 代理（注册表），卸载时自动恢复
- sshuttle 使用 PID 文件管理进程（仅启用时，Linux 限定）

## License

MIT
