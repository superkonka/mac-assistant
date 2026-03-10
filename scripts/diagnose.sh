#!/bin/bash
#
# Mac Assistant 诊断脚本
# 用于排查认证和连接问题
#

echo "═══════════════════════════════════════════════"
echo "  Mac Assistant 诊断工具"
echo "═══════════════════════════════════════════════"
echo ""

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 检查 Kimi CLI
echo "📋 检查 Kimi CLI..."
if command -v kimi &> /dev/null; then
    echo -e "${GREEN}✓${NC} Kimi CLI 已安装"
    kimi --version 2>/dev/null || echo -e "${YELLOW}⚠${NC} 无法获取版本信息"
else
    echo -e "${RED}✗${NC} Kimi CLI 未安装或未在 PATH 中"
    echo "  安装指南: https://github.com/moonshot-ai/kimi-cli"
fi
echo ""

# 检查配置目录
echo "📋 检查配置目录..."
CONFIG_DIR="$HOME/.config/mac-assistant"
OPENCLAW_DIR="$HOME/.openclaw"

if [ -d "$CONFIG_DIR" ]; then
    echo -e "${GREEN}✓${NC} 配置目录存在: $CONFIG_DIR"
    if [ -f "$CONFIG_DIR/kimi_config.json" ]; then
        echo -e "${GREEN}✓${NC} Kimi 配置文件存在"
        echo "  内容预览:"
        cat "$CONFIG_DIR/kimi_config.json" | grep -v "api_key" | head -10
    else
        echo -e "${YELLOW}⚠${NC} Kimi 配置文件不存在"
    fi
else
    echo -e "${YELLOW}⚠${NC} 配置目录不存在: $CONFIG_DIR"
fi

if [ -d "$OPENCLAW_DIR" ]; then
    echo -e "${GREEN}✓${NC} OpenClaw 目录存在: $OPENCLAW_DIR"
    
    # 检查 Agent 配置
    AGENT_DIR="$OPENCLAW_DIR/agents"
    if [ -d "$AGENT_DIR" ]; then
        echo "  已配置的 Agents:"
        for agent_dir in "$AGENT_DIR"/*/; do
            if [ -d "$agent_dir" ]; then
                agent_id=$(basename "$agent_dir")
                auth_file="$agent_dir/auth-profile.json"
                if [ -f "$auth_file" ]; then
                    has_key=$(grep -o '"api_key"' "$auth_file" | wc -l)
                    if [ "$has_key" -gt 0 ]; then
                        echo -e "    ${GREEN}✓${NC} $agent_id (有 API Key)"
                    else
                        echo -e "    ${YELLOW}⚠${NC} $agent_id (无 API Key)"
                    fi
                else
                    echo -e "    ${RED}✗${NC} $agent_id (无认证配置)"
                fi
            fi
        done
    else
        echo -e "${YELLOW}⚠${NC} Agent 目录不存在"
    fi
else
    echo -e "${YELLOW}⚠${NC} OpenClaw 目录不存在: $OPENCLAW_DIR"
fi
echo ""

# 测试网络连接
echo "📋 测试网络连接..."

# 测试 Moonshot API
if curl -s -o /dev/null -w "%{http_code}" https://api.moonshot.cn/v1/models | grep -q "401"; then
    echo -e "${GREEN}✓${NC} Moonshot API 可访问 (401 表示需要认证)"
else
    echo -e "${RED}✗${NC} 无法连接到 Moonshot API"
fi

# 测试 OpenAI API (如果配置了)
if curl -s -o /dev/null -w "%{http_code}" https://api.openai.com/v1/models | grep -q "401"; then
    echo -e "${GREEN}✓${NC} OpenAI API 可访问 (401 表示需要认证)"
fi
echo ""

# 检查日志
echo "📋 检查日志..."
LOG_DIR="$HOME/Documents/MacAssistant/Logs"
if [ -d "$LOG_DIR" ]; then
    echo -e "${GREEN}✓${NC} 日志目录存在: $LOG_DIR"
    
    # 最近的错误
    echo "  最近的错误日志:"
    if [ -f "$LOG_DIR/mac-assistant-current.log" ]; then
        grep -i "error\|401\|403\|认证\|invalid" "$LOG_DIR/mac-assistant-current.log" | tail -5 || echo "    无错误日志"
    else
        echo "    日志文件不存在"
    fi
else
    echo -e "${YELLOW}⚠${NC} 日志目录不存在"
fi
echo ""

echo "═══════════════════════════════════════════════"
echo "  诊断完成"
echo "═══════════════════════════════════════════════"
echo ""
echo "如果仍有问题，请:"
echo "1. 检查 API Key 是否正确（从提供商控制台复制）"
echo "2. 在 Agent 配置向导中点击\"验证 Key\"按钮"
echo "3. 查看日志文件: $LOG_DIR/mac-assistant-current.log"
