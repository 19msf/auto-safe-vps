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

## 完整执行流程

下面按首次接管一台全新 VPS 的顺序执行。多台 VPS 只需在 `inventory.ini` 中增加主机行。

> 建议在自己的电脑、运维机或独立控制节点上运行 Ansible，不要在正在加固的 VPS 上直接控制自己。Windows 请使用 WSL；macOS 和 Linux 可以直接运行。整个过程中始终保留一个已登录的 VPS 终端，并准备好云厂商 VNC/救援控制台。

### 1. 安装 Ansible 和依赖

macOS：

```bash
brew install ansible
```

Ubuntu / Debian / WSL：

```bash
sudo apt update
sudo apt install -y ansible git openssh-client
```

也可以使用较新的 pipx 版本：

```bash
sudo apt install -y pipx
pipx install --include-deps ansible
pipx ensurepath
```

安装项目需要的 collection：

```bash
ansible-galaxy collection install community.general ansible.posix
ansible-playbook --version
```

### 2. 下载项目并准备执行权限

```bash
git clone https://github.com/19msf/auto-safe-vps.git
cd auto-safe-vps
chmod +x run.sh
```

如果脚本来自 Windows 并出现 `bash\r` 或 `bad interpreter`：

```bash
sed -i 's/\r$//' run.sh
chmod +x run.sh
```

### 3. 准备 SSH 密钥

先确认控制端是否已有密钥：

```bash
ls -l ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub
```

如果没有，生成一对新的密钥：

```bash
ssh-keygen -t ed25519 -a 64 -f ~/.ssh/id_ed25519
```

- `~/.ssh/id_ed25519` 是私钥，只能保存在控制端。
- `~/.ssh/id_ed25519.pub` 是公钥，可以写入服务器。

推荐先把公钥放进 VPS 的 root 账号：

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@<VPS_IP>
ssh -i ~/.ssh/id_ed25519 root@<VPS_IP>
```

如果云厂商镜像默认不允许 root，需在后面的 inventory 中填写实际初始用户，并确保该用户有 sudo 权限。

### 4. 创建 inventory.ini 和 config.yml

```bash
cp inventory.ini.example inventory.ini
cp config.yml.example config.yml
chmod 600 inventory.ini config.yml
```

首次连接使用 root、公钥和默认 22 端口，`inventory.ini` 示例：

```ini
[vps]
vps1 ansible_host=<VPS_IP> ansible_port=22 ansible_user=root ansible_ssh_private_key_file=~/.ssh/id_ed25519

[vps:vars]
ansible_become=true
ansible_become_method=sudo
```

多台 VPS：

```ini
[vps]
vps1 ansible_host=<VPS1_IP> ansible_port=22 ansible_user=root ansible_ssh_private_key_file=~/.ssh/id_ed25519
vps2 ansible_host=<VPS2_IP> ansible_port=22 ansible_user=root ansible_ssh_private_key_file=~/.ssh/id_ed25519
vps3 ansible_host=<VPS3_IP> ansible_port=22 ansible_user=root ansible_ssh_private_key_file=~/.ssh/id_ed25519
```

编辑 `config.yml`，首次至少确认以下项目：

```yaml
admin_user:
  name: deploy
  password: "请替换为强密码"
  nopasswd_sudo: false
  ssh_public_keys:
    - "ssh-ed25519 AAAA... 控制端公钥的完整一行"

ssh:
  port: 2233
  permit_root_login: "no"
  password_authentication: "no"
  allowed_ips: []

honeypot:
  enabled: false

login_notify:
  enabled: false
```

获取可以粘贴到 `ssh_public_keys` 的完整公钥：

```bash
cat ~/.ssh/id_ed25519.pub
```

注意：

- `admin_user.password` 必填，至少 8 位；即使禁用 SSH 密码登录，该密码仍可用于 sudo。
- `ssh_public_keys` 必须填写完整的 `.pub` 公钥，绝不能填写或上传私钥。
- 暂时没有 webhook 时，把 `login_notify.enabled` 设为 `false`；启用时必须填写真实 `webhook_url`。
- 首次部署必须让 `honeypot.enabled` 和 `ssh.allowed_ips` 保持关闭/空数组，避免端口冲突或 IP 写错导致锁死。
- `ssh.port` 是稍后要切换到的目标端口；`inventory.ini` 的 `ansible_port` 是当前已经生效的端口。

### 5. 首次连接测试

使用公钥时：

```bash
ansible -i inventory.ini vps -m ping
```

如果首次只能使用 root 密码登录，可暂时删掉主机行中的 `ansible_ssh_private_key_file`，然后执行：

```bash
ansible -i inventory.ini vps -m ping -k
```

连接测试不通过时不要运行加固。先用普通 SSH 排查用户、端口和密钥：

```bash
ssh -i ~/.ssh/id_ed25519 -p 22 root@<VPS_IP>
```

### 6. 阶段一：执行基础加固

使用 root 公钥登录：

```bash
./run.sh
```

使用 root 密码登录：

```bash
./run.sh -k
```

这一阶段会创建管理员、写入公钥、配置 sudo、禁用 root/密码 SSH 登录，并部署 UFW、Fail2ban、自动更新等已启用模块。`site.yml` 不会修改 SSH 端口，SSH 仍监听 inventory 中的当前端口 `22`。

执行成功后不要关闭现有终端，另开一个窗口验证新管理员：

```bash
ssh -i ~/.ssh/id_ed25519 -p 22 deploy@<VPS_IP>
```

只有新管理员能够正常登录并执行 `sudo -v`，才继续下一步。如果失败，保留原终端并通过云厂商控制台修复。

### 7. 阶段二：切换 inventory 到新管理员并复跑

把 `inventory.ini` 中的登录用户从 root 改为 `config.yml` 的 `admin_user.name`，端口仍保持 22：

```ini
vps1 ansible_host=<VPS_IP> ansible_port=22 ansible_user=deploy ansible_ssh_private_key_file=~/.ssh/id_ed25519
```

如果 `nopasswd_sudo: true`：

```bash
./run.sh
```

如果 `nopasswd_sudo: false`：

```bash
./run.sh --ask-become-pass
```

第二次执行用于确认新管理员、sudo 和公钥均可被 Ansible 使用。幂等执行时大多数任务应显示 `ok`，只有状态确实变化的任务显示 `changed`。

### 8. 阶段三：单独切换 SSH 端口

确认阶段二完全成功后，再运行独立端口切换 playbook：

```bash
./run.sh --change-port
```

管理员需要 sudo 密码时：

```bash
./run.sh --change-port --ask-become-pass
```

假设 `config.yml` 中配置了 `ssh.port: 2233`，执行完成后保留原终端，并在新窗口验证：

```bash
ssh -i ~/.ssh/id_ed25519 -p 2233 deploy@<VPS_IP>
```

验证成功后，把 inventory 改成新的当前端口：

```ini
vps1 ansible_host=<VPS_IP> ansible_port=2233 ansible_user=deploy ansible_ssh_private_key_file=~/.ssh/id_ed25519
```

然后再执行一次，让 UFW、Fail2ban 和报告同步到新端口：

```bash
./run.sh
```

### 9. 启用可选模块

SSH 已离开 22 且 inventory 已更新后，才可以让 HFish 使用 22：

```yaml
honeypot:
  enabled: true
  port: 22
```

```bash
./run.sh -t ufw,hfish
```

雷池、1Panel、Cloudflare UFW 和 SSL 模板也应先修改 `config.yml` 中相应模块的 `enabled`，再执行完整 playbook 或对应 tag。WireGuard 当前仍是占位模块，不会自动部署。

```bash
./run.sh -t waf          # 雷池 WAF
./run.sh -t 1panel       # 1Panel
./run.sh -t ssl          # 只生成 SSL 模板，不会自动申请证书
./run.sh -t cf           # Cloudflare UFW
```

首次部署面板后立即查看最新报告，并修改初始密码：

```bash
ls -lt reports/
```

报告可能包含雷池、1Panel 或 HFish 的初始凭据，应按敏感文件保存，不要提交 Git 或发到公开位置。

### 10. 后续增量维护

| 目标 | 命令 |
|---|---|
| 完整幂等执行 | `./run.sh` |
| 只更新 SSH 白名单 | `./run.sh -t allowed_ips` |
| 加/删 UFW 端口 | 编辑 `ufw.allow_rules` 后执行 `./run.sh -t ufw` |
| 更新 SSH 加固配置（不改端口） | `./run.sh -t ssh` |
| 切换 SSH 端口 | `./run.sh --change-port`，完成后更新 inventory |
| 更新 Fail2ban | `./run.sh -t fail2ban` |
| 更新 HFish | `./run.sh -t hfish` |
| 更新登录通知 | `./run.sh -t login_notify` |
| 更新 1Panel | `./run.sh -t 1panel` |
| 更新雷池 WAF | `./run.sh -t waf` |
| 只运行一台 VPS | `./run.sh -l vps2` |
| 单台机器更新白名单 | `./run.sh -l vps2 -t allowed_ips` |
| 跳过模块 | `./run.sh --skip-tags waf,1panel` |

> `common`、`notify` 和 `report` 使用了 `always` 标签，执行单个 tag 时也可能运行基础准备和报告任务。

### 防锁死检查清单

- 每次修改 SSH 用户、端口、密钥或白名单时，都保留一个已登录终端。
- 必须在另一个窗口验证新连接成功后，才能关闭旧终端。
- 首次部署不要配置 `ssh.allowed_ips`；新管理员和新端口验证成功后再逐步加入白名单。
- 确保云厂商安全组同时允许当前 SSH 端口和准备切换的新端口。
- 如果启用 HFish，确认真实 SSH 已经离开 22。
- 面板管理端口不要无条件暴露公网，优先使用固定 IP 白名单或 VPN。

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
