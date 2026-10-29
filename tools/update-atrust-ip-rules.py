#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 aTrust 容器的路由表生成/更新 Clash IP-CIDR 规则。

aTrust 登录后会按策略把内网资源路由下发到容器的 tun 接口（默认 utun7）。
本脚本读取这些路由，合并成最简 CIDR 列表，并写入 Clash Verge 当前档案的
规则扩展文件（rules extension），替换原有的 IP-CIDR,...,aTrust 规则。

用法：
  python3 tools/update-atrust-ip-rules.py                  # 预览（不写文件）
  python3 tools/update-atrust-ip-rules.py --write          # 写入（自动备份）
  python3 tools/update-atrust-ip-rules.py --check          # 对比运行中的 mihomo 规则
  python3 tools/update-atrust-ip-rules.py --print-rules    # 只输出规则行

注意：
- 需要在 VPN 已登录、容器内 tun 接口已拿到内网地址后运行；否则会拒绝执行。
- 写入后需要在 Clash Verge 中重载当前档案（或重启 Clash Verge）才会生效。
- 如果 Docker 网络重建导致容器 eth0 网段变化，可加 --fix-src-cidr 同步
  SRC-IP-CIDR 规则；默认只警告。
- 只处理 IPv4 路由。
"""

import argparse
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
import time

PRIVATE_NETS = (
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
)

BEGIN_MARK = "BEGIN ATRUST-IP-RULES"
END_MARK = "END ATRUST-IP-RULES"

IP_RULE_RE = re.compile(
    r"""^(\s*)-\s*['"]?IP-CIDR,([^,'"]+),([^'"]+)['"]?\s*$""", re.I
)
SRC_RULE_RE = re.compile(
    r"""^(\s*)-\s*['"]?SRC-IP-CIDR,([^,'"]+),([^'"]+)['"]?\s*$""", re.I
)


def die(msg, code=1):
    print(f"错误：{msg}", file=sys.stderr)
    sys.exit(code)


def run_cmd(cmd):
    try:
        r = subprocess.run(cmd, check=True, text=True, capture_output=True)
        return r.stdout
    except FileNotFoundError:
        die(f"找不到命令：{cmd[0]}")
    except subprocess.CalledProcessError as e:
        detail = (e.stderr or e.stdout or "").strip()
        die(f"命令执行失败：{' '.join(cmd)}\n{detail}")


def docker_exec(container, *args):
    return run_cmd(["docker", "exec", container, *args])


def is_private(ip):
    return any(ip in n for n in PRIVATE_NETS)


def collapse(nets):
    return sorted(
        ipaddress.collapse_addresses(nets),
        key=lambda n: (int(n.network_address), n.prefixlen),
    )


def subtract(nets, covered):
    """返回 nets 中未被 covered 覆盖的部分（合并后的 CIDR 列表）。"""
    rem = list(nets)
    for c in covered:
        out = []
        for n in rem:
            if n.subnet_of(c):
                continue
            if c.subnet_of(n):
                out.extend(n.address_exclude(c))
            else:
                out.append(n)
        rem = out
    return collapse(rem)


def get_tun_iface(container, tun):
    out = docker_exec(container, "ip", "-4", "-o", "addr", "show", "dev", tun)
    m = re.search(r"inet\s+([0-9.]+)/(\d+)", out)
    if not m:
        die(f"容器 {container} 里找不到 {tun} 的 IPv4 地址，VPN 可能未登录或未就绪")
    iface = ipaddress.ip_interface(f"{m.group(1)}/{m.group(2)}")
    if not is_private(iface.ip):
        die(
            f"{tun} 的地址是 {iface.ip}，不是内网地址；"
            "VPN 可能还在登录中或未连接，请登录后再运行"
        )
    return iface


def get_routes(container, tun, tun_net):
    out = docker_exec(container, "ip", "-4", "route")
    nets = []
    skipped_default = False
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 3 or "dev" not in parts:
            continue
        if parts[parts.index("dev") + 1] != tun:
            continue
        try:
            net = ipaddress.ip_network(parts[0], strict=False)
        except ValueError:
            continue
        if net.prefixlen == 0:
            skipped_default = True
            continue
        # tun 接口自身所在的网段不是资源路由
        if net.subnet_of(tun_net):
            continue
        nets.append(net)
    if not nets:
        die(f"容器 {container} 的 {tun} 上没有可用的资源路由")
    return collapse(nets), skipped_default


def get_default_route_network(container):
    try:
        out = docker_exec(container, "ip", "-4", "route", "show", "default")
    except SystemExit:
        return None
    m = re.search(r"dev\s+(\S+)", out)
    if not m:
        return None
    dev = m.group(1)
    try:
        out2 = docker_exec(container, "ip", "-4", "-o", "addr", "show", "dev", dev)
    except SystemExit:
        return None
    m2 = re.search(r"inet\s+([0-9.]+)/(\d+)", out2)
    if not m2:
        return None
    return ipaddress.ip_interface(f"{m2.group(1)}/{m2.group(2)}").network


def detect_rules_file(profiles_dir):
    """按 profiles.yaml 的 current -> option.rules 找到当前档案的规则扩展文件。"""
    p = os.path.join(profiles_dir, "profiles.yaml")
    if not os.path.exists(p):
        return None
    txt = open(p, encoding="utf-8").read()
    m = re.search(r"^current:\s*(\S+)", txt, re.M)
    if not m:
        return None
    current = m.group(1)
    blocks = re.split(r"\n(?=- uid:)", txt)

    def find_block(uid):
        for b in blocks:
            if re.search(r"^- uid:\s*" + re.escape(uid) + r"\s*$", b, re.M):
                return b
        return None

    cur_block = find_block(current)
    if not cur_block:
        return None
    m = re.search(r"^\s+rules:\s*(\S+)", cur_block, re.M)
    if not m:
        return None
    rules_block = find_block(m.group(1))
    if not rules_block:
        return None
    f = re.search(r"^\s+file:\s*(\S+)", rules_block, re.M)
    if not f:
        return None
    return os.path.join(profiles_dir, "profiles", f.group(1))


def parse_existing_networks(lines, targets):
    nets = []
    for line in lines:
        m = IP_RULE_RE.match(line)
        if m and m.group(3).strip().lower() in targets:
            try:
                nets.append(ipaddress.ip_network(m.group(2).strip(), strict=False))
            except ValueError:
                pass
    return collapse(nets)


def find_src_rules(lines):
    out = []
    for line in lines:
        m = SRC_RULE_RE.match(line)
        if m and m.group(3).strip().upper() == "DIRECT":
            try:
                out.append(ipaddress.ip_network(m.group(2).strip(), strict=False))
            except ValueError:
                pass
    return out


def edit_rules(lines, new_nets, target, targets, src_net, fix_src):
    """替换/插入自动生成的 IP-CIDR 块，返回新的行列表。"""
    insert_at = None
    indent = "  "
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]

        # 已存在的自动生成块：整块跳过
        if BEGIN_MARK in line:
            if insert_at is None:
                insert_at = len(out)
                indent = re.match(r"^(\s*)", line).group(1)
            while i < len(lines) and END_MARK not in lines[i]:
                i += 1
            i += 1
            continue

        # 旧的 IP-CIDR aTrust 规则：删除，并记录插入位置
        m = IP_RULE_RE.match(line)
        if m and m.group(3).strip().lower() in targets:
            if insert_at is None:
                insert_at = len(out)
                indent = m.group(1)
            i += 1
            continue

        # 可选：同步 SRC-IP-CIDR
        if fix_src and src_net is not None:
            sm = SRC_RULE_RE.match(line)
            if sm and sm.group(3).strip().upper() == "DIRECT":
                line = f"{sm.group(1)}- 'SRC-IP-CIDR,{src_net},DIRECT'"

        out.append(line)
        i += 1

    # 文件里没有任何旧规则时，插到 SRC-IP-CIDR 之后；没有 SRC 规则就插到 prepend: 之后
    if insert_at is None:
        idx = None
        for j, l in enumerate(out):
            if SRC_RULE_RE.match(l):
                idx = j + 1
        if idx is None:
            for j, l in enumerate(out):
                if re.match(r"^\s*prepend:\s*$", l):
                    idx = j + 1
                    break
        if idx is None:
            idx = len(out)
            indent = "  "
        else:
            m = re.match(r"^(\s*)-\s", out[idx]) if idx < len(out) else None
            if m:
                indent = m.group(1)
        insert_at = idx

    block = [f"{indent}# {BEGIN_MARK} (auto-generated, do not edit manually)"]
    block += [f"{indent}- 'IP-CIDR,{n},{target}'" for n in new_nets]
    block.append(f"{indent}# {END_MARK}")
    out[insert_at:insert_at] = block
    return out


def get_runtime_rules(sock, targets):
    if not os.path.exists(sock):
        die(f"找不到 mihomo 的 unix socket：{sock}（可用 --socket 指定）")
    out = subprocess.run(
        ["curl", "-s", "--max-time", "5", "--unix-socket", sock, "http://localhost/rules"],
        capture_output=True,
        text=True,
    )
    if out.returncode != 0 or not out.stdout.strip():
        die(f"无法从 {sock} 读取 mihomo 规则：{out.stderr.strip()}")
    try:
        data = json.loads(out.stdout)
    except json.JSONDecodeError as e:
        die(f"mihomo 返回的规则不是合法 JSON：{e}")
    nets = []
    srcs = []
    for r in data.get("rules", []):
        typ = str(r.get("type", "")).lower()
        proxy = str(r.get("proxy", "")).lower()
        if typ in ("ipcidr", "ip-cidr") and proxy in targets:
            try:
                nets.append(ipaddress.ip_network(r["payload"], strict=False))
            except ValueError:
                pass
        elif typ in ("srcipcidr", "src-ip-cidr") and proxy == "direct":
            try:
                srcs.append(ipaddress.ip_network(r["payload"], strict=False))
            except ValueError:
                pass
    return collapse(nets), srcs


def print_net_list(nets, prefix=""):
    for n in nets:
        print(f"{prefix}{n}")


def main():
    ap = argparse.ArgumentParser(
        description="从 aTrust 容器的路由表生成/更新 Clash IP-CIDR 规则",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("--container", default="atrust", help="docker 容器名（默认 atrust）")
    ap.add_argument("--tun", default="utun7", help="容器内的 tun 接口（默认 utun7）")
    ap.add_argument("--target", default="aTrust", help="规则目标（默认 aTrust）")
    ap.add_argument(
        "--profiles-dir",
        default=os.path.expanduser(
            "~/.local/share/io.github.clash-verge-rev.clash-verge-rev"
        ),
        help="Clash Verge 数据目录",
    )
    ap.add_argument("--file", default=None, help="规则扩展文件（默认自动检测当前档案）")
    ap.add_argument(
        "--socket",
        default=None,
        help="mihomo unix socket（默认 /run/clash-verge-service/users/<uid>/verge-mihomo.sock）",
    )
    ap.add_argument("--write", action="store_true", help="写入规则文件（默认只预览）")
    ap.add_argument("--check", action="store_true", help="对比运行中的 mihomo 规则")
    ap.add_argument("--print-rules", action="store_true", help="只输出生成的规则行")
    ap.add_argument(
        "--fix-src-cidr",
        action="store_true",
        help="写入时同步 SRC-IP-CIDR 到容器默认路由的网段",
    )
    ap.add_argument("--force", action="store_true", help="允许生成明显少于现有规则的集合")
    args = ap.parse_args()

    if args.write and args.check:
        die("--write 和 --check 不能同时使用")
    if args.fix_src_cidr and not args.write:
        die("--fix-src-cidr 需要配合 --write 使用")

    targets = {args.target.lower(), "atrust", "atrust-http"}

    # 1. 读容器路由
    iface = get_tun_iface(args.container, args.tun)
    tun_net = iface.network
    route_nets, skipped_default = get_routes(args.container, args.tun, tun_net)
    src_net = get_default_route_network(args.container)

    # 2. 定位规则文件
    rules_file = args.file or detect_rules_file(args.profiles_dir)
    if not rules_file:
        die("无法从 profiles.yaml 自动检测当前档案的规则文件，请用 --file 指定")
    if not os.path.exists(rules_file):
        die(f"规则文件不存在：{rules_file}")
    lines = open(rules_file, encoding="utf-8").read().splitlines()
    old_nets = parse_existing_networks(lines, targets)
    old_srcs = find_src_rules(lines)

    # 3. --check：对比运行中的规则
    if args.check:
        sock = args.socket or f"/run/clash-verge-service/users/{os.getuid()}/verge-mihomo.sock"
        runtime_nets, runtime_srcs = get_runtime_rules(sock, targets)
        print(f"容器: {args.container}  接口: {args.tun} ({iface})")
        print(f"容器 {args.tun} 路由: {len(route_nets)} 条（合并后）")
        print(f"运行时 IP-CIDR {args.target}: {len(runtime_nets)} 条（合并后）")
        missing = subtract(route_nets, runtime_nets)
        stale = subtract(runtime_nets, route_nets)
        ok = True
        if missing:
            ok = False
            print("\n容器路由有、运行时规则没有：")
            print_net_list(missing, "  ")
        if stale:
            ok = False
            print("\n运行时规则有、容器路由没有（可能已过期）：")
            print_net_list(stale, "  ")
        if src_net is not None:
            if runtime_srcs and src_net not in runtime_srcs:
                ok = False
                print(
                    f"\nSRC-IP-CIDR 不一致：运行时 {', '.join(map(str, runtime_srcs))}，"
                    f"容器默认路由网段 {src_net}"
                )
            else:
                print(f"SRC-IP-CIDR: {src_net}（一致）")
        if not missing and not stale and (src_net is None or not runtime_srcs or src_net in runtime_srcs):
            print("\n规则与路由完全一致。")
        sys.exit(0 if ok else 1)

    # 4. --print-rules：只输出规则行
    if args.print_rules:
        for n in route_nets:
            print(f"- 'IP-CIDR,{n},{args.target}'")
        return

    # 5. 预览 / 写入
    if len(route_nets) < 1:
        die("没有生成任何规则")
    if (
        old_nets
        and len(route_nets) < max(1, len(old_nets) // 2)
        and not args.force
    ):
        die(
            f"新规则 {len(route_nets)} 条，远少于现有 {len(old_nets)} 条；"
            "可能 VPN 未完全登录或策略异常。确认无误后加 --force"
        )

    added = subtract(route_nets, old_nets) if old_nets else route_nets
    removed = subtract(old_nets, route_nets) if old_nets else []

    print(f"容器: {args.container}  接口: {args.tun} ({iface})")
    if src_net is not None:
        print(f"容器默认路由网段: {src_net}")
    print(f"容器 {args.tun} 路由: {len(route_nets)} 条（合并后）")
    print(f"规则文件: {rules_file}")
    print(f"现有 IP-CIDR {args.target}: {len(old_nets)} 条（合并后）")
    print(f"新规则: {len(route_nets)} 条")
    if skipped_default:
        print("警告：忽略了 tun 上的默认路由 0.0.0.0/0")
    if added:
        print(f"\n新增 {len(added)} 段：")
        print_net_list(added, "  ")
    if removed:
        print(f"\n移除 {len(removed)} 段：")
        print_net_list(removed, "  ")

    if src_net is not None:
        if old_srcs and src_net not in old_srcs:
            msg = (
                f"SRC-IP-CIDR 不一致：规则文件里是 {', '.join(map(str, old_srcs))}，"
                f"容器默认路由网段是 {src_net}"
            )
            if args.fix_src_cidr:
                print(f"\n将同步 SRC-IP-CIDR：{msg}")
            else:
                print(f"\n警告：{msg}（可加 --fix-src-cidr 同步）")
        elif not old_srcs:
            print("\n警告：规则文件里没有 SRC-IP-CIDR,...,DIRECT 规则")

    if not args.write:
        print("\n[dry-run] 未写入。加 --write 写入；写入后请在 Clash Verge 中重载当前档案。")
        return

    new_lines = edit_rules(
        lines, route_nets, args.target, targets, src_net, args.fix_src_cidr
    )
    backup = f"{rules_file}.bak.{time.strftime('%Y%m%d-%H%M%S')}"
    n = 1
    while os.path.exists(backup):
        backup = f"{rules_file}.bak.{time.strftime('%Y%m%d-%H%M%S')}-{n}"
        n += 1
    shutil.copy2(rules_file, backup)
    tmp = f"{rules_file}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(new_lines) + "\n")
    shutil.copymode(rules_file, tmp)
    os.replace(tmp, rules_file)
    print(f"\n已写入：{rules_file}")
    print(f"备份：{backup}")
    print("请在 Clash Verge 中重载当前档案（或重启 Clash Verge），然后运行 --check 验证。")


if __name__ == "__main__":
    main()
