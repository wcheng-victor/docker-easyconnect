---
name: update-atrust-ip-rules
description: 把 aTrust 容器 utun7 上的内网资源路由同步为 Clash 的 IP-CIDR 规则。当用户要求同步/更新 aTrust 或 Clash 的 IP 规则、发现 Clash 规则与容器路由表对不上、VPN 资源网段变化、或登录 aTrust 后需要刷新 IP-CIDR 规则时使用。仅适用于 aTrust（tun 接口默认 utun7），仅处理 IPv4。
---

# 同步 aTrust 路由到 Clash IP-CIDR 规则

本仓库的 `tools/update-atrust-ip-rules.py` 会读取 aTrust 容器内 `utun7` 的路由，
合并成最简 CIDR 列表，并更新 Clash Verge 当前档案规则扩展文件里的
`IP-CIDR,...,aTrust` 规则。脚本可重复执行（幂等），写入前自动备份。

## 适用场景

- 用户说“同步/更新 aTrust 的 IP 规则”“Clash 规则和路由表对不上”“VPN 网段变了”。
- aTrust 重新登录或公司策略变化后，容器路由与 Clash 规则出现偏差。
- 需要检查当前 Clash 运行时规则是否覆盖容器所有内网资源。

## 前置条件

1. `atrust` 容器正在运行（`docker ps --filter name=atrust`）。
2. aTrust 已登录（脚本会检查 `utun7` 是否拿到内网地址；未登录会拒绝执行）。
   如果提示未登录，请用户通过 VNC `127.0.0.1:5901` 登录后再试。
3. Clash Verge 正在运行（`--check` 需要读取 mihomo 的 unix socket）。

## 工作流程

在仓库根目录（包含 `tools/update-atrust-ip-rules.py` 的目录）执行：

### 1. 先检查差异

```bash
python3 tools/update-atrust-ip-rules.py --check
```

- 退出码 0 且输出“规则与路由完全一致”：无需改动。
- 退出码 1：把“容器路由有、运行时规则没有”和“运行时规则有、容器路由没有”
  的列表告诉用户。

也可以先跑一次预览（不写文件）：

```bash
python3 tools/update-atrust-ip-rules.py
```

### 2. 写入（用户确认需要更新后）

```bash
python3 tools/update-atrust-ip-rules.py --write
```

脚本会：

- 自动从 `profiles.yaml` 定位当前档案的规则扩展文件；
- 删除旧的 `IP-CIDR,...,aTrust` / `aTrust-http` 行；
- 在原位置插入带标记的自动生成块：
  ```yaml
  # BEGIN ATRUST-IP-RULES (auto-generated, do not edit manually)
  - 'IP-CIDR,10.62.16.0/24,aTrust'
  ...
  # END ATRUST-IP-RULES
  ```
- 备份原文件为 `<规则文件>.bak.<时间戳>`。

### 3. 让 Clash 重载

**修改扩展文件不会自动热重载**（2026-10-29 实测）。写入后必须提醒用户：

- 在 Clash Verge 中重新应用/重载当前档案，或重启 Clash Verge。

### 4. 验证

重载后再运行：

```bash
python3 tools/update-atrust-ip-rules.py --check
```

期望输出“规则与路由完全一致”且退出码为 0。若仍有差异，按提示排查
（规则文件是否写对、Clash 是否真的重载、当前档案是否正确）。

## 常用选项

| 选项 | 说明 |
|---|---|
| `--write` | 写入规则文件（默认只预览） |
| `--check` | 对比运行中的 mihomo 规则与容器路由 |
| `--print-rules` | 只输出生成的规则行，便于管道处理 |
| `--fix-src-cidr` | 写入时同步 `SRC-IP-CIDR` 到容器默认路由网段（Docker 网络重建导致子网变化时使用） |
| `--force` | 允许生成明显少于现有规则的集合（策略确实变小时才用） |
| `--container NAME` | 容器名，默认 `atrust` |
| `--tun IFACE` | tun 接口，默认 `utun7` |
| `--target NAME` | 规则目标，默认 `aTrust` |
| `--file FILE` | 手动指定规则扩展文件（默认自动检测当前档案） |
| `--socket PATH` | mihomo unix socket（默认 `/run/clash-verge-service/users/<uid>/verge-mihomo.sock`） |

## 安全注意事项

- **不要**在 VPN 未登录时强行写入；脚本会拒绝执行，此时应先让用户登录。
- 如果脚本因“新规则远少于现有规则”而拒绝，先确认 VPN 是否完全登录、
  当前账号策略是否真的缩小；确认后再用 `--force`。
- 写入后保留备份，直到 `--check` 验证通过。
- 本脚本只处理 IPv4，且面向 aTrust；EasyConnect 的 `tun0` 或其他 VPN 需要
  自行调整 `--tun` 并确认规则目标。
- 如果 Docker 网络重建导致容器 eth0 网段变化，`--check` 会提示
  `SRC-IP-CIDR` 不一致；使用 `--fix-src-cidr` 一并修正。
