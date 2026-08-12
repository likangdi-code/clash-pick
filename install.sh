#!/usr/bin/env sh
# install.sh — clash-pick 一键安装（macOS / Linux，只装工具，不装 skill）
#
# 用法（终端一行）：
#   curl -fsSL https://raw.githubusercontent.com/likangdi-code/clash-pick/main/install.sh | sh
#
# 效果：
#   - 安装 clash-pick.mjs + clash-pick 命令到 ~/.local/bin 并加入 PATH
#   - 幂等：重复运行只覆盖更新
#   - 只装工具；skill 由各 agent 工具单独部署（deploy-agents.ps1，需要 pwsh）
set -e

REPO=https://raw.githubusercontent.com/likangdi-code/clash-pick/main
INSTALL_DIR="${HOME}/.local/bin"

# 1. 前置检查：Node.js
if ! command -v node >/dev/null 2>&1; then
  echo "✗ 未找到 Node.js，请先安装（https://nodejs.org）后重试。" >&2
  exit 1
fi

# 2. 创建目录
mkdir -p "$INSTALL_DIR"

# 3. 下载主脚本
echo "下载 clash-pick.mjs -> $INSTALL_DIR"
curl -fsSL "$REPO/clash-pick.mjs" -o "$INSTALL_DIR/clash-pick.mjs"

# 4. 生成 clash-pick 命令包装
cat > "$INSTALL_DIR/clash-pick" <<'WRAP'
#!/usr/bin/env sh
exec node "$(dirname "$0")/clash-pick.mjs" "$@"
WRAP
chmod +x "$INSTALL_DIR/clash-pick"

# 5. 加入 PATH（幂等：追加到第一个存在的 rc 文件）
case ":$PATH:" in
  *":$INSTALL_DIR:"*) : ;;
  *)
    rc=""
    for f in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
      if [ -f "$f" ]; then rc="$f"; break; fi
    done
    if [ -n "$rc" ]; then
      {
        echo ""
        echo 'export PATH="$HOME/.local/bin:$PATH"'
      } >> "$rc"
      echo "已追加 PATH 到 $rc"
    else
      echo "提示：请把 $INSTALL_DIR 加入 PATH（未找到 .zshrc/.bashrc/.profile）"
    fi
    ;;
esac

# 6. 下载 deploy-agents.ps1 备用（skill 部署脚本，不执行）
if ! curl -fsSL "$REPO/deploy-agents.ps1" -o "$INSTALL_DIR/deploy-agents.ps1" 2>/dev/null; then
  echo "（deploy-agents.ps1 下载失败，可稍后手动获取）"
fi

# 7. 汇总提示
echo ""
echo "✓ clash-pick 工具安装完成（未安装 skill）。"
echo "  新开终端后可直接："
echo "    clash-pick list"
echo "    clash-pick pick \"https://example.com/big-file.zip\""
echo ""
echo "▶ 部署 skill 到本机所有 agent 工具（需 pwsh；macOS: brew install powershell）："
echo "    pwsh -File \"$INSTALL_DIR/deploy-agents.ps1\""
echo "  只装到当前 agent："
echo "    pwsh -File \"$INSTALL_DIR/deploy-agents.ps1\" -Agent claude"
echo "  可用的 -Agent 值：claude / gemini / codex / opencode / hermes / openclaw / grok / agents"
