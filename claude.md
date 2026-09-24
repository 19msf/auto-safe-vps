# claude.md

> 给 Claude Code 协作的项目说明 —— 让 AI 能在不踩坑的前提下帮你改这个仓库。

## 项目是什么

`auto-safe-vps` 是一套 **Ansible 一键 VPS 安全加固** 工具，目标系统 Ubuntu 22.04/24.04 与 Debian 12。一份 inventory，一条命令把多台 VPS 全部加固完。

入口：
- `./run.sh` → `site.yml` → 各 `roles/*`（默认全量加固，不改 SSH 端口）
- `./run.sh --change-port` → `change_port.yml`（独立 playbook，专门切 sshd 监听端口）

## 仓库布局

```
.
├── site.yml                 # 主 playbook，编排所有 role；不主动改 SSH 端口
├── change_port.yml          # 独立 playbook：仅切换 sshd 监听端口（隔离锁死风险）
├── run.sh                   # 用户入口脚本，--change-port 切到 change_port.yml
├── ansible.cfg              # Ansible 全局配置
├── config.yml.example       # 配置模板（真实 config.yml 不入库）
├── inventory.ini.example    # 主机清单模板（真实 inventory.ini 不入库）
├── group_vars/              # 全局变量
├── roles/
│   ├── common/              # 基础包；启用容器模块时检查/安装 Docker 与 Compose
│   ├── user/                # 创建 sudo 账号、写公钥
│   ├── ssh_hardening/       # 禁 root / 禁密码 / 公钥；不改端口（端口归 change_port.yml）
│   ├── fail2ban/            # 暴破封禁 + webhook 通知
│   ├── ufw/                 # 防火墙规则（增量同步）
│   ├── limit_ssh_ip/        # SSH 白名单（可选）
│   ├── honeypot/            # 22 端口蜜罐
│   ├── login_notify/        # PAM 登录 webhook
│   ├── notify/              # webhook 公共逻辑
│   ├── unattended_upgrades/ # 自动安全更新
│   ├── bbr/                 # BBR
│   ├── safeline_waf/        # 长亭雷池 WAF（Docker）
│   ├── one_panel/           # 1Panel 面板
│   ├── ssl_template/        # nginx 防 IP 泄露模板
│   ├── wireguard_placeholder/  # 占位，未实现
│   └── report/              # 主机端汇总数据
├── templates/
│   └── summary_report.md.j2 # 汇总报告模板
├── files/                   # 需要拷到目标机的文件
└── docs/TODO.md             # 设计权衡 / 待补
```

## 关键约定（改代码前先看）

1. **Debian 系限定**：`site.yml` 的 `pre_tasks` 会断言 `os_family == 'Debian'`，新加 role 时如果用了发行版相关的 module（apt 等），不需要再做兼容。

2. **Docker 已在 `common` role 统一处理**：启用 `safeline_waf` 或 `one_panel` 等容器模块时，`common` 会保证 docker + docker-compose-plugin + 开机自启就绪；未启用时跳过 Docker。依赖容器的新 role 应扩展 `common_docker_required` 的条件，不要自行重复安装。

3. **每个 role 必须往 `host_report` 写一笔**，便于最终生成报告。模式：
   ```yaml
   - name: 记录到报告
     ansible.builtin.set_fact:
       host_report: >-
         {{ host_report | combine({
           'actions': host_report.actions + ['xxx 已完成'],
           'access_points': host_report.access_points + [{'name': '...', 'address': '...'}],
           'credentials': host_report.credentials + [...],
           'warnings': host_report.warnings + [...]
         }) }}
   ```

4. **敏感配置不入库**：`config.yml`、`inventory.ini`、`group_vars/all/vault.yml`、`reports/`、`*.pem` 全部已 gitignore。修改 ignore 前先确认你不会把密码/密钥推上去。

5. **SSH 加固使用 drop-in 文件**：常规加固走 `99-autosafe.conf`（不写 Port），切端口走 `change_port.yml` 写的 `98-autosafe-port.conf`。两个 drop-in 文件分别承担"安全配置"和"端口"，互不干扰。改 SSH 行为前先想清楚是哪一类。

6. **改 SSH 端口是独立 playbook（`change_port.yml`）**：site.yml 永远不主动改端口，因为：
   - Debian 12 / Ubuntu 22.10+ 的 socket activation 需要先关 `ssh.socket` 再 `enable ssh.service`，否则 `Port` 指令会被忽略
   - **Ubuntu 24.04 的 ssh.service 默认 `Requires=ssh.socket`，mask 掉 socket 后 service 启动会失败**——`change_port.yml` 用 drop-in `override.conf` 把 Requires/Wants 重置为空再启动
   - 改端口要 `wait_for` + `reset_connection`，跟普通幂等任务的执行模型不同，混在 site.yml 里会让一次性失败回滚成本太高
   - inventory 的 `ansible_port` 是 source of truth；site.yml 的 `effective_ssh_port = ansible_port`，UFW / fail2ban / limit_ssh_ip 自动跟随
   - 跑 change_port.yml 默认带 `--ask-become-pass`（deploy 已 NOPASSWD 时被忽略，作为兜底）

7. **首次执行有锁死风险**：
   - 第一次 `./run.sh` 不要碰端口，跑通整机后再 `./run.sh --change-port`
   - 启用 SSH 白名单前先确认控制端出口 IP 稳定（家宽/手机网络容易漂）
   - 想留逃生通道：暂时把 `password_authentication: "yes"` 留着，跑完再关
   - 蜜罐与 SSH 不能同端口（site.yml pre_tasks 有 assert 兜底）

8. **22 端口的 UFW 放行永远不删**：
   - 22 是留给蜜罐的——切端口后 sshd 在 2233，22 让蜜罐接管，攻击者扫 22 → 进蜜罐 → 被记录 + 飞书通知
   - 删 22 的 UFW 规则 = 蜜罐废了（攻击者扫不到 22 端口）
   - `roles/ufw/tasks/main.yml` 的 SSH 规则是"add 当前 effective_ssh_port"+"add 蜜罐端口"，**永远不主动 delete**；删除端口必须用户在 `config.yml` 的 `ufw.allow_rules` 里显式写 `state: absent`
   - 写新逻辑时不要"切完端口就删旧端口"——这是错的

9. **幂等性**：所有 role 必须可重复执行。新写 role 时 `register` + `changed_when` / `creates` / `stat` 检测要给到位，避免每次跑都触发"变更"。

## 常见任务模式

- **加新端口到 UFW**：编辑 `config.yml` 里 `ufw.allow_rules`，跑 `./run.sh -t ufw`
- **更新 SSH 白名单**：编辑 `ssh.allowed_ips`，跑 `./run.sh -t allowed_ips`
- **删除某条 UFW 规则**：把 `state: present` 改成 `state: absent`（保留行更利于审计）
- **切换 SSH 端口**：`./run.sh --change-port --ask-become-pass`（独立 playbook，-K 兜底；deploy 已 NOPASSWD 时被忽略），跑完手改 inventory 的 `ansible_port`，再 `./run.sh` 让 UFW / fail2ban 同步
- **跑单个 role**：`./run.sh -t <tag>`，tag 看 `site.yml` 里每个 role 的 `tags:`

## 工作流提示给 Claude

- 改 role 的任务前，先读 `site.yml` 确认它的执行顺序和 `when` 条件
- 任何「需要 docker 才能跑」的逻辑：依赖 `common` 已处理，不要再写一次
- 写新 role 时复制现有 role 的目录结构（`tasks/` `defaults/` 必备，按需加 `templates/` `handlers/`）
- 改完一个 role 后跑 `ansible-playbook --syntax-check site.yml` 自检；改 `change_port.yml` 也要单独 syntax-check
- 拒绝在 role 里硬编码绝对路径以外的"魔法值"，全部走 `defaults/main.yml` 或 `config.yml`
- **不要把改 SSH 端口的逻辑搬回 ssh_hardening role**——这是有意拆开的设计
