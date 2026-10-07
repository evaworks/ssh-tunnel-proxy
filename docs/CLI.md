# 命令参考（CLI Reference）

本文件是 ssh-tunnel-proxy 的**完整**命令参考。所有条目都由
`tests/smoke.sh` 的「文档一致性」检查与实现逐一比对，改动代码不同步更新文档会导致测试失败。

- [1. Linux 安装器 `install.sh`](#1-linux-安装器-installsh)
- [2. Linux 运行控制 `tunnel-proxy`](#2-linux-运行控制-tunnel-proxy)
- [3. Linux 卸载 `uninstall.sh`](#3-linux-卸载-uninstallsh)
- [4. 辅助脚本（Linux）](#4-辅助脚本linux)
- [5. Windows](#5-windows)
- [6. 测试](#6-测试)
- [7. 环境变量（覆盖钩子）](#7-环境变量覆盖钩子)
- [8. 运行期对象速查](#8-运行期对象速查)
- [9. 退出码约定](#9-退出码约定)

---

## 1. Linux 安装器 `install.sh`

```bash
bash install.sh --server user@host [选项]
```

| 选项 | 默认 | 说明 |
|------|------|------|
| `--server <user@host>` | **必填** | 中继服务器；必须包含 `@` |
| `--tunnel-port <n>` | `2222` | 反向隧道在中继上的端口 |
| `--socks5-port <n>` | `1080` | 本地 SOCKS5 端口 |
| `--ssh-port <n>` | `22` | 中继 SSH 端口 |
| `--only-reverse` | — | 只部署反向隧道（跳过 SOCKS5） |
| `--only-socks5` | — | 只部署 SOCKS5（跳过反向隧道） |
| `--enable-sshuttle` | — | 安装并启用 sshuttle（仍注入代理环境变量） |
| `--global` | — | 全流量模式：所有 TCP+DNS 走隧道；等价于 `--enable-sshuttle --proxy-mode global`，且不再注入环境变量 |
| `--proxy-mode <env\|global>` | `env` | 显式指定代理变量注入策略 |
| `--no-bypass-lan` | — | 内网网段也走隧道（默认旁路） |
| `--local-only` | — | 只配置本机：跳过公钥上传与中继配置（`scripts/local-setup.sh` 就是它的包装） |
| `--verbose` | — | 打印实际执行的每条命令 |
| `--dry-run` | — | 只预览，不写任何文件 |
| `--help` | — | 打印帮助并退出 0 |

约束：端口必须是 1–65535 的整数；`--only-reverse` 与 `--only-socks5` 互斥；
未知选项或缺少参数一律退出码 1。

---

## 2. Linux 运行控制 `tunnel-proxy`

安装后同时存在两个入口，行为一致：

- **shell 函数**（写入 `~/.bashrc`，若存在 `~/.zshrc` 也写入）——能直接修改**当前终端**的代理变量；
- **可执行文件** `/usr/local/bin/tunnel-proxy`——只控制系统服务与桌面代理。

### 2.1 子命令

| 命令 | 说明 |
|------|------|
| `tunnel-proxy` | 不带参数：状态摘要 + 常用命令提示（退出 0） |
| `tunnel-proxy help` / `--help` / `-h` | 打印命令参考（退出 0） |
| `tunnel-proxy on` | 开：启动服务；按当前模式注入代理变量或启动 sshuttle；同步 GNOME 代理 |
| `tunnel-proxy on --global` | 先切到全流量模式，再启动 |
| `tunnel-proxy on --env` / `--local` | 先切回环境变量模式，再启动 |
| `tunnel-proxy off` | 关：停止服务、清理残留重定向规则、清除本终端代理变量 |
| `tunnel-proxy restart` | 重启（`off` → 1 秒 → `on`） |
| `tunnel-proxy status [--json]` | 查看状态（免 sudo）；`--json` 输出机器可读结果 |
| `tunnel-proxy global` | 切到全流量模式（写入配置 + 启用并启动 sshuttle） |
| `tunnel-proxy local` | 切回环境变量模式（停用 sshuttle） |
| `tunnel-proxy mode` | 查询当前模式 |
| `tunnel-proxy mode env\|global` | 切换模式的原始命令 |
| `tunnel-proxy check` | 只校验 `tunnel.conf`，非法则退出 1 |
| `tunnel-proxy doctor` | 端到端体检，有失败项则退出 1 |
| `tunnel-proxy env` | 打印 `export`/`unset` 语句，供 `eval "$(tunnel-proxy env)"` |
| `tunnel-proxy rescue` | 紧急救援：停服务 + 强制清除 sshuttle 重定向规则 |

### 2.2 别名

| 别名 | 等价于 |
|------|--------|
| `start` | `on` |
| `stop` | `off` |
| `mode global` | `global` |
| `mode env` | `local` |

### 2.3 `doctor` 选项

| 选项 | 说明 |
|------|------|
| `--deep` | 追加"真实出网"测试（env 模式走 SOCKS；global 模式不带代理变量直连） |
| `--relay` | 追加"中继侧反向端口是否在监听"检查（需要免密 SSH） |
| `--json` | JSON 输出，含 `"ok": true/false` |
| `--quiet` | 只打印失败项 |

检查项：配置合法性 → sshuttle 服务与 iptables 规则（global 模式）→ unit 是否存在 →
服务是否 active → SOCKS5 端口是否监听 → 监听者是否为 `ssh` → SOCKS5 协议握手 →
（`--deep`）真实出网 → （`--relay`）中继反向端口 → GNOME 代理一致性。

---

## 3. Linux 卸载 `uninstall.sh`

```bash
bash uninstall.sh
```

无参数。交互式 `[y/N]` 确认；停止并删除服务、清理 sshuttle iptables 规则、恢复桌面代理原值、
删除配置目录与控制脚本、移除 `~/.bashrc` / `~/.zshrc` 中的托管块、回滚中继的
`GatewayPorts` 与防火墙规则。

---

## 4. 辅助脚本（Linux）

| 命令 | 说明 |
|------|------|
| `bash scripts/local-setup.sh <install.sh 的选项>` | 等价于 `install.sh --local-only "$@"` |
| `sudo bash scripts/remote-setup.sh [tunnel-port] [ssh-port] [old-tunnel-port]` | 在中继服务器上单独执行：修正 `GatewayPorts`、校验 `sshd -T`、开/关防火墙端口 |
| `ssh user@relay 'sudo bash -s -- 2222 22' < scripts/remote-setup.sh` | 远程执行同一脚本 |

---

## 5. Windows

### 5.1 安装器 `install.ps1`（需管理员）

```powershell
.\install.ps1 -Server user@host [选项]
```

| 参数 | 默认 | 说明 |
|------|------|------|
| `-Server <user@host>` | **必填** | 中继服务器 |
| `-TunnelPort <n>` | `2222` | 反向隧道端口 |
| `-Socks5Port <n>` | `1080` | 本地 SOCKS5 端口 |
| `-SshPort <n>` | `22` | 中继 SSH 端口 |
| `-OnlyReverse` | — | 只部署反向隧道 |
| `-OnlySocks5` | — | 只部署 SOCKS5 |
| `-NoBypassLan` | — | 内网也走代理 |
| `-EnableSshuttle` | — | Windows 不支持 sshuttle，仅提示 |
| `-Verbose` | — | 声明保留，当前未使用 |

### 5.2 运行控制

```powershell
tunnel-proxy start | stop | restart | status
```

由安装时写入的 `%ProgramData%\ssh-tunnel-proxy\tunnel-proxy.cmd` 转发到
`tunnel-proxy.ps1 -Action <动作>`。`status` 不需要管理员，其余需要。

### 5.3 卸载与辅助

| 命令 | 说明 |
|------|------|
| `.\uninstall.ps1` | 无参数；需管理员；恢复系统代理原值并回滚中继 |
| `.\scripts\local-setup.ps1 -Server <user@host> [-TunnelPort] [-Socks5Port] [-SshPort] [-OnlyReverse] [-OnlySocks5] [-NoBypassLan]` | 只配置本机 |

---

## 6. 测试

| 命令 | 说明 |
|------|------|
| `bash tests/smoke.sh` | 冒烟测试：语法、参数与退出码、内嵌脚本一致性、shell 集成幂等、配置校验、doctor（含真实 SOCKS5 握手）、模式切换、单元渲染校验、文档一致性。免 root、免网络 |
| `pwsh -NoProfile -File tests/windows-parse.ps1` | PowerShell 语法解析（+ 可选 PSScriptAnalyzer） |

CI：`.github/workflows/ci.yml`（Linux 跑 smoke + 非阻断 shellcheck；Windows 跑 parse）。

---

## 7. 环境变量（覆盖钩子）

这些变量主要供测试或特殊部署使用，默认值即标准路径。

| 变量 | 作用 |
|------|------|
| `SSH_TUNNEL_PROXY_CONF_DIR` | 覆盖配置目录（默认 `/etc/ssh-tunnel-proxy`）；`tunnel-proxy` 与 shell 集成块都遵循 |
| `SSH_TUNNEL_PROXY_SYSTEMD_DIR` | 覆盖 systemd unit 目录（默认 `/etc/systemd/system`） |
| `SSHD_CONFIG` | `remote-setup.sh` 要修改的 sshd 配置文件（默认 `/etc/ssh/sshd_config`） |
| `SSHUTTLE_CLEANUP_BIN` | 覆盖 sshuttle 清理脚本路径（默认 `/usr/local/bin/sshuttle-cleanup`） |
| `TMPDIR` | 安装日志目录（默认 `/tmp`，日志文件名 `ssh-tunnel-proxy-install.log`） |

---

## 8. 运行期对象速查

| 对象 | Linux | Windows |
|------|-------|---------|
| 反向隧道 | `tunnel-reverse.service` | NSSM `ssh-tunnel-reverse` |
| SOCKS5 | `tunnel-socks5.service` | NSSM `ssh-tunnel-socks5` |
| 透明代理 | `tunnel-sshuttle.service` | 不支持 |
| 配置文件 | `/etc/ssh-tunnel-proxy/tunnel.conf` | `%ProgramData%\ssh-tunnel-proxy\tunnel.json` |
| 桌面代理原值 | `/etc/ssh-tunnel-proxy/gnome-proxy.state` | `%ProgramData%\ssh-tunnel-proxy\proxy-backup.json` |
| 控制脚本 | `/usr/local/bin/tunnel-proxy` | `tunnel-proxy.ps1` + `tunnel-proxy.cmd` |
| sshuttle 清理 | `/usr/local/bin/sshuttle-cleanup` | — |
| 日志 | `journalctl -u tunnel-*` | `…\{reverse,socks5}-{stdout,stderr}.log`（10 MB 轮转） |

---

## 9. 退出码约定

| 命令 | 0 | 1 |
|------|---|---|
| `install.sh` | 安装完成且服务均 active | 参数错误、安装失败、服务未 active |
| `tunnel-proxy on/off/restart/global/local/mode/rescue` | 成功 | 配置非法、服务启动失败、缺少 sshuttle/unit |
| `tunnel-proxy status/check/env/help`（及无参数） | 成功 | 配置非法（`check`/`env`） |
| `tunnel-proxy doctor` | 无 fail 项 | 存在 fail 项（warn 不影响退出码） |
| `uninstall.sh` | 卸载完成 | 用户取消以外的失败 |
