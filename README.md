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

需要 sudo 权限（脚本内部按需调用 sudo，请**不要**整个脚本用 `sudo` 运行，
否则服务会以 root 身份运行且密钥落在 `/root`）。

```bash
# 方式一：本地安装（推荐）
bash install.sh --server root@你的服务器IP

# 方式二：远程安装（只需输入一次中继服务器密码）
curl -sSL https://raw.githubusercontent.com/evaworks/ssh-tunnel-proxy/master/install.sh | \
  bash -s -- --server root@你的服务器IP
```

### Windows

需要管理员权限运行 PowerShell。

```powershell
# 管理员 PowerShell
Set-ExecutionPolicy RemoteSigned -Scope Process -Force
iwr -useb https://raw.githubusercontent.com/evaworks/ssh-tunnel-proxy/master/install.ps1 -OutFile install.ps1
.\install.ps1 -Server root@你的服务器IP
```

> 也可以直接 `iwr -useb ... | iex`，此时会交互式提示输入 `-Server`。
> 注意反向隧道转发到本机 `localhost:22`，Windows 需要额外启用 **OpenSSH Server**
> （安装脚本只安装 Client 并给出提示，不会自动改动你的系统功能）。

### 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--server` | (必填) | 中继服务器地址，格式 `user@host` |
| `--tunnel-port` | `2222` | 反向隧道映射到中继服务器的端口 |
| `--socks5-port` | `1080` | 本地 SOCKS5 代理端口 |
| `--ssh-port` | `22` | 中继服务器 SSH 端口（非常规端口时使用） |
| `--only-reverse` | — | 仅部署反向隧道（跳过 SOCKS5） |
| `--only-socks5` | — | 仅部署 SOCKS5 代理（跳过反向隧道） |
| `--enable-sshuttle` | — | 安装并启用 sshuttle 透明代理 |
| `--global` | — | **全流量模式**：所有 TCP+DNS 走隧道（隐含 `--enable-sshuttle`），且不再注入 shell 代理变量 |
| `--proxy-mode <mode>` | `env` | `env`＝注入代理环境变量；`global`＝透明代理、不注入变量 |
| `--local-only` | — | 只配置本机（跳过公钥上传与中继配置，供 `scripts/local-setup.sh` 使用） |
| `--verbose` | — | 显示详细执行输出 |
| `--dry-run` | — | 仅预览要执行的操作（不会写任何文件） |

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

> 本页只讲常用操作；**完整的命令/参数清单见 [docs/CLI.md](docs/CLI.md)**。

### 从其他设备 SSH 连接到本机

```bash
# 方式一：跳板登录
ssh -J root@中继IP 你的用户名@localhost -p 2222

# 方式二：使用 SSH config（安装时已生成）
ssh tunnel-proxy
```

### 启动 & 关闭（快速参考）

```bash
# ─── 日常开关（start/stop 是 on/off 的别名，同样可用） ───
tunnel-proxy on         # 启动隧道 + 开启系统代理
tunnel-proxy off        # 关闭隧道 + 关闭系统代理

# ─── 开机自启（执行一次，重启后自动运行） ───
sudo systemctl enable tunnel-socks5.service tunnel-reverse.service

# ─── 取消开机自启 ───
sudo systemctl disable tunnel-socks5.service tunnel-reverse.service

# ─── 立即启动/停止/重启 + 设置开机自启 ───
sudo systemctl enable --now tunnel-socks5.service tunnel-reverse.service
sudo systemctl disable --now tunnel-socks5.service tunnel-reverse.service
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

使用 `tunnel-proxy` 统一开关隧道并自动同步系统代理设置：

**Linux：日常只要三条命令**

```bash
tunnel-proxy on       # 开：启动隧道 + 设置本终端代理变量（+ GNOME 代理）
tunnel-proxy off      # 关：停隧道 + 清掉本终端代理变量
tunnel-proxy status   # 看状态（免 sudo）
tunnel-proxy          # 不带参数 = 同样的状态摘要 + 命令提示
```

切换"所有程序都走代理"（全流量模式）：

```bash
sudo tunnel-proxy on --global    # 切到全流量模式并启动（推荐）
sudo tunnel-proxy global         # 只切模式，不重启服务
sudo tunnel-proxy local          # 切回环境变量模式
```

换一台中继服务器（如果你有多台）：

```bash
tunnel-proxy server                                   # 看当前用的是哪台
sudo tunnel-proxy server root@1.2.3.4                 # 切换过去（自动重启服务）
sudo tunnel-proxy server root@1.2.3.4 --ssh-port 2200 --tunnel-port 2222
sudo tunnel-proxy server root@1.2.3.4 --cleanup-old   # 顺带回滚旧中继的 GatewayPorts/防火墙
```

其余为高级/排障命令：

```bash
tunnel-proxy status --json       # 机器可读输出
sudo tunnel-proxy doctor         # 端到端体检（配置/单元/服务/端口/监听者/SOCKS5 握手）
sudo tunnel-proxy doctor --deep --relay   # 再测真实出网 + 中继反向端口
tunnel-proxy check               # 只校验配置（systemd 启动前也会调用它）
eval "$(tunnel-proxy env)"       # 非 bash shell / CI 用
sudo tunnel-proxy rescue         # 紧急救援：停隧道 + 清除残留重定向规则
tunnel-proxy help                # 完整命令参考
```

> 旧名字全部保留为别名，已有脚本不用改：
> `start`=`on`、`stop`=`off`、`mode global`=`global`、`mode env`=`local`。

`tunnel-proxy` 是一个 shell 函数（定义在 `~/.bashrc`，若存在 `~/.zshrc` 也会写入），
所以 `on`/`off` 能直接改**当前终端**的代理环境变量；不带参数的 `status`/`doctor`/`help`
不需要 sudo。
新开的终端会在启动时检查 SOCKS5 端口是否在监听，只在隧道真正可用时才设置代理。

`doctor` 会依次检查：配置合法性 → （global 模式）sshuttle 服务与 iptables 规则 →
unit 是否存在 → 服务是否 active → 端口是否监听 → 监听者是否真的是我们的 ssh →
**SOCKS5 协议握手是否成功**（`--deep` 再验证真实出网：env 模式走 SOCKS，
global 模式**不带代理变量**直连以证明透明代理生效；`--relay` 验证中继侧反向端口）。
任何一项失败返回非 0，可直接用于监控。

> 直接执行 `/usr/local/bin/tunnel-proxy on`（或 `sudo tunnel-proxy on`）只会控制
> 服务与 GNOME 代理，不会修改当前终端的环境变量——那是 shell 函数的职责；
> 函数内部通过 `tunnel-proxy env` 获取变量，两者不会不一致。

> **配置写错会立刻可见**：unit 带有 `ExecStartPre=/usr/local/bin/tunnel-proxy check`，
> 非法配置会在启动瞬间失败并把原因写进 journal，`tunnel-proxy check` / `doctor` 也会直接报出来。
>
> **断线重连不受限**：三个 unit 都**故意不设** `StartLimit`——中继或网络中断多久都会一直重试
> （这是这个工具的核心行为；加限流会导致断网几分钟后隧道永久停在 failed）。

**Linux（systemd 原生命令）：**

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

**Windows：**
```powershell
# 启动隧道 + 启用系统代理
tunnel-proxy start

# 关闭隧道 + 禁用系统代理
tunnel-proxy stop

# 重启
tunnel-proxy restart

# 查看状态
tunnel-proxy status
```

> 安装时会写入 `%ProgramData%\ssh-tunnel-proxy\tunnel-proxy.cmd` 并加入用户 PATH，
> 所以上面的命令可直接使用（底层调用同目录的 `tunnel-proxy.ps1`）。
> `start`/`stop`/`restart` 需要管理员权限（脚本会自行校验）。
> NSSM 的服务日志已启用轮转（单文件上限 10 MB）。

**Windows（NSSM 原生命令）：**

```powershell
# 设置 nssm 命令别名（一次设置，后续可直接用 nssm）
$env:Path += ";C:\Program Files\nssm"

# 查看状态
nssm status ssh-tunnel-reverse
nssm status ssh-tunnel-socks5

# 临时关闭/启动（nssm 每个子命令只接受一个服务名）
nssm stop ssh-tunnel-reverse
nssm stop ssh-tunnel-socks5
nssm start ssh-tunnel-reverse
nssm start ssh-tunnel-socks5

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

### 全流量模式（所有程序都走代理，仅 Linux）

如果你希望**整台机器所有程序**都走隧道（包括 systemd 服务、其他用户、Docker 宿主机进程、
以及那些不读代理环境变量的程序），用 sshuttle 的透明代理模式：

```bash
bash install.sh --server root@1.2.3.4 --global
```

**如果安装时没加 `--global`，也可以事后随时切换**，不需要重跑安装脚本：

```bash
# 前提：sshuttle 已安装、tunnel-sshuttle.service 已存在
#（用 --only-reverse 装且没开 sshuttle 的情况，请重跑安装脚本加 --global）
sudo tunnel-proxy on --global     # 切到全局模式并启动（= global + on）
eval "$(tunnel-proxy env)"        # 清掉当前终端里残留的 SOCKS 变量
sudo tunnel-proxy doctor --deep   # 验证透明代理生效（不带代理变量直连成功）
```

切回环境变量模式：`sudo tunnel-proxy local`（会停用 sshuttle）。
如果 `tunnel-sshuttle.service` 不存在，命令会明确提示重跑 `install.sh --server <中继> --global`。

`--global` 等价于 `--enable-sshuttle --proxy-mode global`，安装后：

- `tunnel-proxy on/off/status` 会一并管理 `tunnel-sshuttle.service`；
- **不再向新终端注入 `ALL_PROXY/HTTP_PROXY/...`** —— 因为流量已经在网络层被接管，
  注入 SOCKS 变量反而会让不支持 SOCKS 的库（`requests` 未装 PySocks、
  `huggingface_hub`、部分 Rust 下载器）报错；
- 校验：`sudo tunnel-proxy doctor --deep`（`--deep` 在 global 模式下会**不带任何代理变量**
  直接发请求，成功即证明透明代理生效）。

| 覆盖 | 不覆盖 |
|---|---|
| 全部进程的 **TCP**（IPv4/IPv6），含 root/systemd/其他用户 | **UDP**（除 DNS 外），例如 HTTP/3(QUIC) 会直连 |
| **DNS**（`--dns`，通过 TCP 隧道解析） | 使用独立网络命名空间的**容器**（Docker 容器内部） |
| 不受环境变量影响的程序 | 已配置 `--exclude` 的内网网段（默认旁路 127/10/172.16/192.168） |

#### 熔断与救援（防止"隧道挂了整机断网"）

全流量模式最危险的场景是：sshuttle 停了，但它安装的 iptables 重定向规则还在——
那样**所有流量都会被送进一个已死的隧道**。本项目做了四道防护：

1. **退出即清理**：`ExecStopPost=/usr/local/bin/sshuttle-cleanup` + `TimeoutStopSec=15`，
   无论正常停止还是崩溃退出都会清规则（所以允许无限重试是安全的）。
2. **`tunnel-proxy off` 二次兜底**：停止服务后再查一次 iptables，发现残留就再清一遍。
3. **`doctor` 主动发现**：服务没跑但规则还在 → 直接报
   `stale sshuttle iptables rules are still redirecting traffic`。
4. **`rescue` 一键恢复**：停服务 + 强制清规则 + 打印恢复步骤。

真出问题时一条命令恢复：

```bash
sudo tunnel-proxy rescue      # 停所有服务 + 强制清规则 + 提示如何恢复终端变量
```

> 需要连 UDP/QUIC 或容器整体走代理时，透明 TCP 代理不够，应改用 WireGuard 之类的
> 三层 VPN——那超出本项目范围。
>
> 运行时想临时切换模式，可改 `/etc/ssh-tunnel-proxy/tunnel.conf` 里的 `PROXY_MODE`
> （`env` / `global`）后重开终端；`tunnel-proxy status` 会显示当前模式。

### 修改端口等配置

**Linux：**

```bash
# 方式一：编辑配置文件，然后重启服务
sudo vim /etc/ssh-tunnel-proxy/tunnel.conf
sudo systemctl restart tunnel-reverse
sudo systemctl restart tunnel-socks5
source ~/.bashrc        # 让当前终端的代理变量跟随新端口

# 方式二：直接重新运行安装脚本（自动检测重部署并重启服务）
./install.sh --server root@1.2.3.4 --tunnel-port 8888
```

> `tunnel-proxy` 的 shell 集成块会在**每次读取配置时**解析 `tunnel.conf`，
> 因此改端口不会留下写死端口的旧配置；重跑安装脚本还会刷新
> `/usr/local/bin/tunnel-proxy`、`~/.ssh/config` 与中继侧多余的防火墙规则。

**Windows：**

```powershell
# 重新运行安装脚本（自动检测重部署并重启服务）
.\install.ps1 -Server root@1.2.3.4 -TunnelPort 8888
```

## 卸载

### Linux

```bash
# 本地卸载（推荐）
bash uninstall.sh

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
sudo sed -i '/GatewayPorts/d' /etc/ssh/sshd_config
sudo systemctl restart sshd
```

## 开发与测试

无需 root、无需网络即可运行冒烟测试（58 项），覆盖：

- 参数解析/退出码、`--dry-run` 不写文件；
- 四份内嵌脚本与 `scripts/` 下 canonical 脚本逐字节一致（防漂移）；
- shell 集成块的幂等性与 legacy 保护、`~/.ssh/config` 刷新；
- 中继 GatewayPorts 替换与失败回滚；
- 控制脚本的 GNOME 代理保存/恢复；
- 配置校验（非法端口/host/布尔值会被拒绝）、`env` 可 `eval`、`status --json` 合法、
  `doctor` 在"无监听"时失败、在"有可用 SOCKS5 监听者"时通过（含真实握手）；
- 渲染出的 systemd unit 通过 `systemd-analyze verify`。

```bash
bash tests/smoke.sh
```

Windows 脚本可做静态校验（语法解析 + 可选的 PSScriptAnalyzer）：

```powershell
pwsh -NoProfile -File tests/windows-parse.ps1
```

仓库自带 [`.github/workflows/ci.yml`](.github/workflows/ci.yml)：Linux 作业跑
`tests/smoke.sh`（外加非阻断的 shellcheck），Windows 作业跑
`tests/windows-parse.ps1`。

> 内嵌副本的"漂移"由测试断言守住：
> `install.sh` 的 `TUNNELSCRIPT`/`REMOTESCRIPT`、`install.ps1` 的 fallback
> 必须与 `scripts/` 下的对应文件逐字节一致，改动 canonical 后必须同步重新内嵌，
> 否则 CI 会失败。

## 技术细节

| 组件 | 原理 | Linux 守护 | Windows 守护 |
|------|------|------------|--------------|
| 反向隧道 | `ssh -R` 将本地 22 → 中继服务器 2222 | systemd + SSH（断线重连） | NSSM + SSH（断线重连） |
| SOCKS5 代理 | `ssh -D` 动态端口转发 | systemd + SSH（断线重连） | NSSM + SSH（断线重连） |
| 透明代理 | SSH 隧道 + iptables 规则 | systemd + sshuttle（可选） | 不支持（无 iptables） |
| 配置持久化 | 配置文件 | `/etc/ssh-tunnel-proxy/tunnel.conf` | `%ProgramData%\ssh-tunnel-proxy\tunnel.json` |
| 系统代理 | 桌面/注册表代理 | GNOME `org.gnome.system.proxy`（socks host/port） | `HKCU\...\Internet Settings` 的 `socks=127.0.0.1:1080` |

### 安全措施

- sshd_config 修改前备份至 `.bak.ssh-tunnel-proxy`；重启前 `sshd -t` 验证，失败自动回滚
- GatewayPorts 会替换文件中**已存在**的该指令（sshd 只认第一个值），并用 `sshd -T` 复核生效结果
- 中继端口变更时，安装脚本会顺手删除上一次遗留的防火墙规则
- Linux: 服务以普通用户身份运行（`User=` 指令）
- 系统代理在改动前会**保存原值**，`tunnel-proxy off` / 卸载时恢复（GNOME 保存到
  `/etc/ssh-tunnel-proxy/gnome-proxy.state`，Windows 保存到 `proxy-backup.json`）
- shell 集成块只删除**同时存在起止标记**的区段，避免误删用户 `.bashrc`/`.zshrc`

### 使用时请注意

- 反向隧道会把本机 **22 端口**映射到中继的公网端口，脚本会开放该端口但**不做来源限制**。
  建议在中继侧用防火墙或 `sshd_config` 的 `Match Address` 限制来源 IP。
- 脚本使用用户日常的 `~/.ssh/id_ed25519`（如果已有则复用），中继被攻破等于暴露该密钥；
  高安全场景建议改用专用密钥。
- 本机需要运行 sshd 才能被反向访问；安装脚本会检测并提示，但不会自动安装。
- `--dry-run` 现在不会写任何文件（包括 systemd unit 与 `/usr/local/bin`）。
- 安装失败（例如服务未 active）会以非 0 退出码返回，便于自动化判断。

## License

MIT
