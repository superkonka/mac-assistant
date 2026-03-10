#!/bin/bash
# 测试日志生成脚本

LOGS_DIR="$HOME/Documents/MacAssistant/ConversationLogs"
mkdir -p "$LOGS_DIR"

SESSION_ID="session-test-$(date +%s)"
LOG_FILE="$LOGS_DIR/$SESSION_ID.jsonl"

echo "生成测试日志: $SESSION_ID"

# 场景 1: 正常的对话
cat >> "$LOG_FILE" << 'EOF'
{"id":"$(uuidgen)","timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","type":"systemResponse","sessionId":"$SESSION_ID","response":"=== 新会话开始: $SESSION_ID ==="}
EOF

# 用户输入：普通消息
echo '{"id":"e1","timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","type":"userInput","sessionId":"'$SESSION_ID'","input":"你好，请介绍一下自己","parsedInput":{"original":"你好，请介绍一下自己","cleanText":"你好，请介绍一下自己","hasAgentMention":false,"agentMention":null,"hasSkillCommand":false,"skillCommand":null,"detectedSkill":null,"suggestedAgent":null}}' >> "$LOG_FILE"

# 系统响应
echo '{"id":"e2","timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","type":"systemResponse","sessionId":"'$SESSION_ID'","response":"你好！我是 MacAssistant，你的 macOS AI 助手。","agentName":"Kimi Local","duration":1.2}' >> "$LOG_FILE"

# 场景 2: @Agent 切换
echo '{"id":"e3","timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","type":"userInput","sessionId":"'$SESSION_ID'","input":"@GPT-4V 分析一下这个设计稿","parsedInput":{"original":"@GPT-4V 分析一下这个设计稿","cleanText":"分析一下这个设计稿","hasAgentMention":true,"agentMention":"GPT-4V","hasSkillCommand":false,"skillCommand":null,"detectedSkill":null,"suggestedAgent":null}}' >> "$LOG_FILE"

echo '{"id":"e4","timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","type":"agentMentioned","sessionId":"'$SESSION_ID'","input":"@GPT-4V 分析一下这个设计稿","metadata":{"agent":"GPT-4V"}}' >> "$LOG_FILE"

echo '{"id":"e5","timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","type":"agentSwitch","sessionId":"'$SESSION_ID'","agentName":"GPT-4V Vision","metadata":{"from":"Kimi Local","to":"GPT-4V Vision","reason":"通过 @GPT-4V 指定"}}' >> "$LOG_FILE"

# 场景 3: 检测到能力缺口
echo '{"id":"e6","timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","type":"capabilityGap","sessionId":"'$SESSION_ID'","input":"分析一下这个设计稿","metadata":{"missing_capability":"vision","suggested_providers":"openai,anthropic,moonshot"}}' >> "$LOG_FILE"

# 场景 4: Skill 检测被拒绝
echo '{"id":"e7","timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","type":"userInput","sessionId":"'$SESSION_ID'","input":"截个图看看","parsedInput":{"original":"截个图看看","cleanText":"看看","hasAgentMention":false,"agentMention":null,"hasSkillCommand":false,"skillCommand":null,"detectedSkill":"截图分析","suggestedAgent":null}}' >> "$LOG_FILE"

echo '{"id":"e8","timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","type":"skillDetected","sessionId":"'$SESSION_ID'","input":"截个图看看","metadata":{"skill":"截图分析","confidence":"medium"}}' >> "$LOG_FILE"

# 用户拒绝确认，发送其他内容
echo '{"id":"e9","timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","type":"userInput","sessionId":"'$SESSION_ID'","input":"不用了，我就是说说","parsedInput":{"original":"不用了，我就是说说","cleanText":"不用了，我就是说说","hasAgentMention":false,"agentMention":null,"hasSkillCommand":false,"skillCommand":null,"detectedSkill":null,"suggestedAgent":null}}' >> "$LOG_FILE"

# 场景 5: 响应超时
echo '{"id":"e10","timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","type":"userInput","sessionId":"'$SESSION_ID'","input":"写一段很长的代码","parsedInput":{"original":"写一段很长的代码","cleanText":"写一段很长的代码","hasAgentMention":false,"agentMention":null,"hasSkillCommand":false,"skillCommand":null,"detectedSkill":null,"suggestedAgent":null}}' >> "$LOG_FILE"

echo '{"id":"e11","timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","type":"systemResponse","sessionId":"'$SESSION_ID'","response":"[代码内容...]","agentName":"GPT-4V Vision","duration":12.5}' >> "$LOG_FILE"

# 场景 6: 错误
echo '{"id":"e12","timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","type":"error","sessionId":"'$SESSION_ID'","input":"测试错误","error":"Connection timeout to OpenClaw bridge"}' >> "$LOG_FILE"

# 生成统计文件
cat > "$LOGS_DIR/${SESSION_ID}-stats.json" << EOF
{
  "sessionId": "$SESSION_ID",
  "startTime": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "eventCount": 12,
  "userMessageCount": 6,
  "agentSwitchCount": 1,
  "skillExecutionCount": 0,
  "errorCount": 1,
  "avgResponseTime": 4.5,
  "activeAgent": "GPT-4V Vision"
}
EOF

echo "测试日志已生成: $LOG_FILE"
echo "统计文件: $LOGS_DIR/${SESSION_ID}-stats.json"
echo ""
echo "查看日志:"
echo "cat $LOG_FILE | head -5"
