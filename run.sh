#!/usr/bin/env bash
# 一键执行 VPS 安全加固
set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -f inventory.ini ]]; then
  echo "[!] 没有发现 inventory.ini，请先复制：cp inventory.ini.example inventory.ini 并修改"
  exit 1
fi

if [[ ! -f config.yml ]]; then
  echo "[!] 没有发现 config.yml，请先复制：cp config.yml.example config.yml 并修改"
  exit 1
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "[!] 未检测到 ansible-playbook，请先安装：brew install ansible 或 pipx install ansible"
  exit 1
fi

# 解析自定义参数：--change-port 切换到 change_port.yml playbook
PLAYBOOK="site.yml"
EXTRA_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --change-port)
      PLAYBOOK="change_port.yml"
      ;;
    *)
      EXTRA_ARGS+=("$arg")
      ;;
  esac
done

if [[ "$PLAYBOOK" == "change_port.yml" ]]; then
  echo "[*] 单独切换 SSH 端口（change_port.yml）"
  echo "    - sshd 监听端口将切到 config.yml 里的 ssh.port"
  echo "    - 跑完后请按提示手动改 inventory.ini 的 ansible_port / ansible_user"
  echo "    - 如果 deploy 账号未配置 NOPASSWD sudo，需加 --ask-become-pass：./run.sh --change-port --ask-become-pass"
else
  echo "[*] 开始执行安全加固（site.yml）"
  echo "    可加参数 -k （SSH 密码登录）/ --ask-become-pass / -t <tag>"
  echo "    切换 SSH 端口请单独跑：./run.sh --change-port --ask-become-pass"
fi

ansible-playbook -i inventory.ini "$PLAYBOOK" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}

echo
echo "[√] 全部完成，最终报告位于 ./reports/ 目录"
