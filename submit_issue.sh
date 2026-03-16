#!/bin/bash
# GitHub Issue 提交脚本

echo "======================================"
echo "MacAssistant Bug Report 提交脚本"
echo "======================================"
echo ""

# 检查 gh CLI
if ! command -v gh &> /dev/null; then
    echo "错误: 未安装 gh CLI"
    echo "请运行: brew install gh"
    exit 1
fi

# 检查认证状态
if ! gh auth status &> /dev/null; then
    echo "未登录 GitHub CLI，请先登录:"
    echo ""
    gh auth login
fi

echo ""
echo "正在创建 Issue..."
echo ""

cd "$(dirname "$0")"

gh issue create \
  --title '[Bug] 应用启动后CPU占用100%导致系统无响应' \
  --body-file /tmp/github_issue.md \
  --label bug,performance,critical

echo ""
echo "完成!"
