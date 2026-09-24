# auto-safe-vps

把 LINUX DO 那篇《VPS 基本安全措施》里的可自动化部分，整理成一套 **Ansible 一键加固** 工具。
适用：Ubuntu 22.04 / 24.04 / Debian 12 的多台 VPS（写一份 inventory，一条命令全部跑完）。

## 功能清单

| 模块 | 自动化 | 说明 |
|---|---|---|
| 创建 sudo 账号、写公钥 | ✅ | 失败前必先建账号 |
| SSH 加固（改端口、禁 root、禁密码） | ✅ | 用 `/etc/ssh/sshd_config.d/99-autosafe.conf`，避免污染主文件（评论区 wordpure 的建议） |
| Fail2ban | ✅ | maxretry/bantime 可配；**封禁/解封通过 webhook 通知**（与登录同一渠道） |
| UFW 防火墙 + 禁 ping | ✅ | |
| **限定 SSH 登录 IP（白名单）** | ✅ | 在 `config.yml` 的 `ssh.allowed_ips` 里配置；最终报告中体现；可单独跑 `-t allowed_ips` 增量更新 |
| **HFish 蜜罐** | ✅ | Docker 部署；SSH 蜜罐使用 22，带中文 Web 管理台、攻击记录和告警配置 |
| 登录通知（webhook） | ✅（默认开启） | PAM + 企业微信 / 飞书 / Slack / 通用 JSON；webhook 在 config.yml 里填 |
| 自动安全更新 | ✅ | unattended-upgrades |
| BBR | ✅ | 如果已经开启了BBR，不再做额外 sysctl |
| **长亭雷池 WAF** | ✅ | 可选；Docker 一键部署，随机账号密码 / 控制台地址写入报告 |
| **1Panel** | ✅ | 可选；使用官方 v2 在线入口安装最新稳定版，支持非交互参数，真实访问信息写入报告 |
| **SSL 防 IP 泄露**（nginx 模板） | ⚠️ 半自动 | 生成 `ssl_reject_handshake` 模板 + acme.sh，但 **不会自动 reload nginx**（避免覆盖现网） |
| WireGuard | ❌ TODO | 见 `docs/TODO.md` 设计权衡 |
| **Cloudflare UFW 锁源** | ✅ | 可选；80/443 仅允许 Cloudflare 官方 IP，并由 systemd timer 定期同步 |
| Ubuntu Pro / 三网优化 | ❌ | 按需求不集成 |

## 快速开始

### 1. 准备控制端（Mac / Linux 任一即可）

**macOS：**
```bash
brew install ansible
```

**Ubuntu / Debian：**
```bash
sudo apt update && sudo apt install -y ansible
# 或者更新版（pipx 安装到当前用户）
sudo apt install -y pipx && pipx install --include-deps ansible
```

**RHEL / CentOS / Rocky / Alma：**
```bash
sudo dnf install -y epel-release && sudo dnf install -y ansible
```

**Arch：**
```bash
sudo pacman -S ansible
```

**任意发行版（pip 通用）：**
```bash
python3 -m pip install --user ansible
```

装完后补上必要 collection：
```bash
ansible-galaxy collection install community.general ansible.posix
```

### 2. 准备配置（真实文件不会被提交）
```bash
cp inventory.ini.example inventory.ini
cp config.yml.example   config.yml
vim inventory.ini   # 3 台 VPS 的 IP / 用户 / 私钥
vim config.yml      # 管理员账号、密码、SSH 端口、白名单 IP、webhook 等
```

> ⚠️ **必填项**：`admin_user.password`（>=8 位）、`login_notify.webhook_url`（如启用通知）。
> 缺失时 `pre_tasks` 会立即报错，不会半路停下。
> 当同时禁用 root 和密码登录时，目标管理员账号还必须至少有一把能被 `ssh-keygen` 验证的公钥，否则剧本会在应用 SSH 加固前安全中止。

### 3. 执行
```bash
./run.sh
# 首次还在用 root 密码登录时：
./run.sh -k --ask-become-pass
```

### 4. 首次执行流程（重要）

剧本采用**双 playbook 设计**，把"改 SSH 端口"这个唯一不可逆 + 容易锁死的操作隔离成独立入口：

| Playbook | 命令 | 干什么 |
|---|---|---|
| `site.yml` | `./run.sh` | 执行基础安全加固；1Panel、WAF 等可选模块仅在配置中启用后部署。**SSH 端口跟随 inventory `ansible_port`**，不主动改。可反复幂等执行。 |
| `change_port.yml` | `./run.sh --change-port --ask-become-pass` | 单独切 sshd 监听端口（关 ssh.socket → 改 Port → wait_for）。跑完手动改 inventory 后再跑 `./run.sh`。`-K` 是兜底，deploy 账号已 NOPASSWD sudo 时会被忽略。 |

#### 时间线（推荐）

```
T0  config.yml: ssh.port=2233 honeypot.enabled=false
    inventory: ansible_port=22 ansible_user=root
T1  ./run.sh -k --ask-become-pass        ← 阶段 1：root 密码起手，跑完整机加固
T2  剧本里：建 deploy / 写公钥 / 禁 root / 禁密码 / UFW 放行 22 / fail2ban；按配置部署可选模块
T3  剧本结束。SSH 还在 22，但只能用 deploy + key 登
T4  另一个终端验证：ssh -p 22 deploy@<VPS_IP>     ← 必须能进，否则别关 T1 的会话！
T5  改 inventory：ansible_port=22 ansible_user=deploy（保持 22，只换用户）
T6  ./run.sh                              ← 阶段 2：用 deploy 重跑一遍，确认 ok=changed=0
T7  ./run.sh --change-port --ask-become-pass  ← 阶段 3：切端口（-K 兜底，免密时被忽略）
T8  另一个终端验证：ssh -p 2233 deploy@<VPS_IP>
T9  改 inventory：ansible_port=2233       UFW 已在 T7 即时放行新端口；22 永远不删（给蜜罐留的）
T10 HFish 想用 22：把 honeypot.enabled 改 true，./run.sh -t ufw,hfish
```

#### 关键决策

- **SSH 端口的"当前值"由 inventory 的 `ansible_port` 决定**（site.yml 里叫 `effective_ssh_port`）。改了 inventory，UFW / fail2ban / limit_ssh_ip 自动同步，不需要手改 config。
- **首次部署 honeypot 必须关**（默认 `enabled: false`）：因为 SSH 还在 22，蜜罐也想占 22 会冲突，site.yml 的 pre_tasks assert 会直接拦下。
- **`./run.sh --change-port` 是独立 playbook**：不会被 `./run.sh` 自动触发，必须显式执行。

#### ⚠️ 安全护栏（防锁死）

- **任何阶段执行前都保留当前 SSH 终端**，等新窗口验证连接成功后再关。
- **SSH 白名单 `ssh.allowed_ips` 第一次先留空**（默认就是空数组），等 deploy 账号能稳定登录后再加。填错 IP 会被锁死，只能用 VPS 厂商控制台的 VNC / 救援模式恢复。
- **change_port 前确认 deploy 公钥能用**：阶段 2 必须先跑通——只有 deploy 能用 key 登 22，才有资格切端口。
- 如果启用了雷池或 1Panel，第一次跑后请从 `reports/summary-*.md` 保存随机生成的访问地址和初始凭据，并尽快修改密码。

### 5. 单独执行某个 role（增量维护）

剧本里每个 role 都打了 tag，可以只跑想要的部分。**最常见场景**：后续在 `config.yml` 里加了新的白名单 IP，只需：

```bash
./run.sh -t allowed_ips        # 只跑 limit_ssh_ip
```

完整 tag 列表：

| 目标 | 命令 |
|---|---|
| 只更新 SSH 白名单 | `./run.sh -t allowed_ips` |
| **加 / 删一个开放端口** | 编辑 `config.yml` 的 `ufw.allow_rules` 后 `./run.sh -t ufw`（增量同步：present 加，absent 删） |
| 只改 SSH 加固配置（不改端口） | `./run.sh -t ssh` |
| **切换 SSH 端口**（独立 playbook） | `./run.sh --change-port --ask-become-pass`，跑完手改 inventory 的 ansible_port |
| 只装 / 重配 fail2ban | `./run.sh -t fail2ban` |
| 只调整 UFW | `./run.sh -t ufw` |
| 只装 / 检查 HFish 蜜罐 | `./run.sh -t hfish` |
| 只刷新登录通知 | `./run.sh -t login_notify` |
| 只装 1Panel | `./run.sh -t 1panel` |
| 只装雷池 WAF | `./run.sh -t waf` |
| 只生成 SSL 模板 | `./run.sh -t ssl` |
| 只跑某台 VPS | `./run.sh -l vps2` |
| 跑某台机器 + 只白名单 | `./run.sh -l vps2 -t allowed_ips` |
| 跳过某个模块 | `./run.sh --skip-tags waf,1panel` |

> `common` / `notify` / `report` 标了 `always`，跑任意 tag 时也会一起执行（保证基础包、通知脚本和报告都是最新的）。

执行完后，最终报告会落到 `./reports/summary-YYYYMMDD-HHMMSS.md`，按 3 台机器逐台列出：
- 已执行的安全操作
- SSH 新端口、管理员账号 / 初始密码
- 雷池 WAF 控制台地址 + 安装脚本随机生成的初始账号密码（仅首次安装可从日志解析）
- 1Panel 入口地址 + 账号 + 密码 + 端口（未在配置中指定的字段由官方安装脚本生成）
- HFish 管理台地址与首次默认凭据（登录后必须立即修改）
- SSH 白名单
- 待手动处理的项（SSL / WireGuard）

## 安全提示

- 报告里 SSH 管理员密码仅以“见 config.yml”占位呈现，不回显明文；雷池和 1Panel 的随机初始凭据会写入首次安装报告。
- 1Panel 使用官方 v2 非交互安装接口。端口、入口、账号和密码可以在 `config.yml` 中指定；未指定时使用官方脚本生成值，剧本会从 `1pctl user-info` 抓取真实信息写入报告。
- `config.yml` / `inventory.ini` 已在 `.gitignore`；建议加密保存（git-crypt / sops / age）。
- 修改 SSH 端口是**独立的 playbook**（`./run.sh --change-port --ask-become-pass`），不会被默认 `./run.sh` 自动触发。改完保留旧终端，新终端用新端口验证后再断开。`-K` 是兜底，deploy 账号已 NOPASSWD sudo 时会被忽略。
- `inventory.ini` / `config.yml` / `reports/` 已在 `.gitignore`。

## HFish 蜜罐运维

HFish 使用官方 Docker 镜像部署，管理台地址为
`https://<VPS_IP>:4433/web/`。首次默认账号为 `admin`、密码为
`HFish2021`，登录后必须立即修改。

- 真实 SSH 端口由 inventory 的 `ansible_port` 决定；HFish SSH 蜜罐默认使用 `22`。
- 持久化数据位于 `/usr/share/hfish`，编排文件位于 `/opt/hfish/compose.yaml`。
- `4434` 用于 HFish 节点回传；单机部署时 UFW 不向公网放行该端口。
- `management_allowed_ips` 留空会公网放行管理台；建议首次登录后改成固定管理 IP 白名单。
- HFish 自带邮件、Syslog、Webhook、企业微信、钉钉和飞书等告警，请在 HFish 管理台中配置。

常用命令：

```bash
sudo docker ps --filter name=hfish
sudo docker logs --tail 100 hfish
sudo docker compose -f /opt/hfish/compose.yaml restart
```

## 1Panel 面板运维

1Panel v2 官方安装脚本已经支持非交互参数。本项目使用官方最新在线入口；未在 `config.yml` 指定的端口、入口、账号和密码由安装脚本生成。剧本会：
1. 装完后用 `1pctl user-info` 抓取真实端口 / 入口 / 账号 / 密码
2. 把真实端口加进 ufw 放行
3. 把以上信息**完整写进 `reports/summary-*.md`**

但密码留在报告里有泄露风险——**强烈建议登录后立刻改账号密码**。

### 查看当前真实信息

```bash
sudo 1pctl user-info
```

输出形如：

```
Panel address: http://<IP>:14295/a34938bcea
Panel user: 16e1f5e98e
Panel password: f1fcaeffc2
```

### service 名（systemctl 操作时用这两个）

⚠️ v2 的 systemd unit 不叫 `1panel`，而是 **`1panel-core`** 和 **`1panel-agent`**：

```bash
sudo systemctl status 1panel-core --no-pager   # ✅ 正确
sudo systemctl status 1panel                   # ❌ 报 "Unit not found"
```

更建议用 `1pctl` 自带的封装：

```bash
sudo 1pctl status      # 显示两个 service 状态
sudo 1pctl restart     # 重启
sudo 1pctl stop / start
```

### 改账号 / 密码 / 端口

```bash
sudo 1pctl update password   # 改密码
sudo 1pctl update username   # 改用户名
sudo 1pctl update port       # 改端口
```

> 改端口后需要 ufw 同步：`sudo ufw allow 新端口/tcp comment "1Panel"; sudo ufw delete allow 旧端口/tcp`

改安全入口（URL 中的随机串）需登录控制台 → 「面板设置」→「安全入口」。

### 浏览器访问

打开报告里给的 `Panel address`，**注意 URL 末尾的入口路径不能少**——去掉之后会跳"404 Not Found"。

## 雷池 WAF 账号密码运维

雷池 setup.sh 安装时会自动调用 `mgt-cli reset-admin --once` **随机生成**初始 admin 账号和密码并打印到日志。本剧本会**从日志解析这两个值并写进最终报告**——和 1Panel 同一套思路（不再尝试 `--username/--password` 同步 config 里的值，因为不同版本支持的参数差异大）。

### 查看安装时输出的初始账号密码

剧本把雷池安装日志保留在 VPS 上 `/tmp/safeline-install.log`：

```bash
sudo grep -E "Initial (username|password)" /tmp/safeline-install.log
```

期望输出：

```
[INFO] Initial username：admin
[INFO] Initial password：1gy2uvnx
```

> 安装日志在 VPS 重启后可能被清理；若已丢失，按下面"忘记密码"重置即可。

### 忘记密码 / 重新随机一个

```bash
sudo docker exec safeline-mgt resetadmin
```

输出会再次打印新的随机密码，立刻可用。

### 改成自己想要的账号密码（只能在控制台 UI 里改）

雷池**没有命令行直接设密码的能力**（官方文档明确）。流程：

1. 用上面拿到的随机账号密码登录 `https://<VPS_IP>:9443/`
2. 进控制台 → **通用设置** → **控制台管理** → **控制台用户管理**
3. 编辑用户名 / 密码，可顺手开启 **TOTP 二次验证**（强烈推荐）

> 浏览器第一次会警告"自签证书不安全"——雷池默认自签 HTTPS，点「高级 → 继续访问」即可。

### Ansible 安装时的密码逻辑

`safeline_waf` role 在**首次安装**时只做以下事：
1. 修补 setup.sh 让 `confirm()` 和 `validate_directory()` 不再卡死非交互执行
2. 跑 setup.sh，输出落到 `/tmp/safeline-install.log`
3. 从日志 grep 出 `Initial username/password`，写到最终报告
4. ufw 放行 9443（或 config 里的 `console_port`）

**重跑 role 不会再改已存在的密码**——marker `/data/safeline/docker-compose.yaml` 存在时所有安装/解析任务都被跳过。想改密码请用上面的命令或控制台。

## 目录结构
```
auto-safe-vps/
├── ansible.cfg
├── site.yml                 # 主入口：全部安全加固
├── change_port.yml          # 单独切 SSH 端口（独立 playbook）
├── run.sh                   # ./run.sh / ./run.sh --change-port
├── inventory.ini.example
├── config.yml.example
├── templates/
│   └── summary_report.md.j2 # 最终报告模板
├── roles/
│   ├── common, user, ssh_hardening, fail2ban, ufw,
│   ├── limit_ssh_ip, honeypot, login_notify,
│   ├── unattended_upgrades, bbr,
│   ├── safeline_waf, one_panel, ssl_template,
│   └── wireguard_placeholder, report
└── docs/TODO.md
```
