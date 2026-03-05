#!/usr/bin/env python3
"""
Mac Assistant Backend Service
FastAPI + OpenClaw + Kimi CLI Integration
"""

import asyncio
import json
import subprocess
from typing import Optional, Dict, Any, List
from datetime import datetime
from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import uvicorn

# 配置
APP_NAME = "Mac Assistant"
VERSION = "1.0.0"
PORT = 8765

# 全局状态
class AppState:
    def __init__(self):
        self.active_connections: List[WebSocket] = []
        self.conversation_history: List[Dict[str, Any]] = []
        self.current_task: Optional[asyncio.Task] = None
        self.openclaw_available = False
        self.kimi_available = False

state = AppState()

# Pydantic 模型
class ChatMessage(BaseModel):
    role: str  # "user" | "assistant" | "system"
    content: str
    timestamp: Optional[str] = None
    metadata: Optional[Dict[str, Any]] = None

class CommandRequest(BaseModel):
    command: str
    context: Optional[str] = None
    use_openclaw: bool = True
    use_kimi: bool = True

class SystemAction(BaseModel):
    action: str  # "screenshot", "clipboard", "notify", "open_app", etc.
    params: Optional[Dict[str, Any]] = None

# 生命周期管理
@asynccontextmanager
async def lifespan(app: FastAPI):
    """启动和关闭时的处理"""
    print(f"🚀 {APP_NAME} v{VERSION} 启动中...")
    
    # 检查依赖
    await check_dependencies()
    
    yield
    
    # 清理
    print("👋 服务关闭")
    if state.current_task:
        state.current_task.cancel()

app = FastAPI(
    title=APP_NAME,
    version=VERSION,
    lifespan=lifespan
)

# CORS 配置
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:3000", "app://localhost"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ============== 依赖检查 ==============

async def check_dependencies():
    """检查 OpenClaw 和 Kimi CLI 是否可用"""
    # 检查 OpenClaw
    try:
        result = subprocess.run(
            ["openclaw", "--version"],
            capture_output=True,
            text=True,
            timeout=5
        )
        state.openclaw_available = result.returncode == 0
        print(f"✅ OpenClaw: {'可用' if state.openclaw_available else '不可用'}")
    except Exception as e:
        print(f"⚠️ OpenClaw 检查失败: {e}")
        state.openclaw_available = False
    
    # 检查 Kimi CLI
    try:
        result = subprocess.run(
            ["kimi", "--version"],
            capture_output=True,
            text=True,
            timeout=5
        )
        state.kimi_available = result.returncode == 0
        print(f"✅ Kimi CLI: {'可用' if state.kimi_available else '不可用'}")
    except Exception as e:
        print(f"⚠️ Kimi CLI 检查失败: {e}")
        state.kimi_available = False

# ============== OpenClaw 封装 ==============

async def call_openclaw(prompt: str, context: str = "") -> str:
    """调用 OpenClaw Gateway"""
    if not state.openclaw_available:
        return "❌ OpenClaw 不可用"
    
    try:
        # 构建完整 prompt
        full_prompt = f"""Context: {context}

Task: {prompt}

请提供简洁、可操作的回答。"""
        
        # 使用 OpenClaw CLI
        proc = await asyncio.create_subprocess_exec(
            "openclaw", "ask", full_prompt,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=30)
        
        if proc.returncode == 0:
            return stdout.decode().strip()
        else:
            return f"⚠️ OpenClaw 错误: {stderr.decode()}"
    except asyncio.TimeoutError:
        return "⏱️ OpenClaw 请求超时"
    except Exception as e:
        return f"❌ OpenClaw 调用失败: {str(e)}"

# ============== Kimi CLI 封装 ==============

async def call_kimi(prompt: str, files: List[str] = None) -> str:
    """调用 Kimi CLI"""
    if not state.kimi_available:
        return "❌ Kimi CLI 不可用"
    
    try:
        cmd = ["kimi", "-p", prompt]
        if files:
            for f in files:
                cmd.extend(["-f", f])
        
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=60)
        
        if proc.returncode == 0:
            return stdout.decode().strip()
        else:
            return f"⚠️ Kimi 错误: {stderr.decode()}"
    except asyncio.TimeoutError:
        return "⏱️ Kimi 请求超时"
    except Exception as e:
        return f"❌ Kimi 调用失败: {str(e)}"

# ============== 系统操作 ==============

async def execute_system_action(action: SystemAction) -> Dict[str, Any]:
    """执行系统操作"""
    result = {"success": False, "message": ""}
    
    try:
        if action.action == "screenshot":
            # 截图
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            path = f"/tmp/screenshot_{timestamp}.png"
            proc = await asyncio.create_subprocess_shell(
                f"screencapture -x {path}",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            await proc.communicate()
            result["success"] = True
            result["data"] = {"path": path}
            
        elif action.action == "clipboard":
            # 获取/设置剪贴板
            if action.params and "text" in action.params:
                # 设置剪贴板
                text = action.params["text"]
                proc = await asyncio.create_subprocess_shell(
                    f'echo "{text}" | pbcopy',
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE
                )
                await proc.communicate()
                result["success"] = True
            else:
                # 获取剪贴板
                proc = await asyncio.create_subprocess_shell(
                    "pbpaste",
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE
                )
                stdout, _ = await proc.communicate()
                result["success"] = True
                result["data"] = {"text": stdout.decode().strip()}
                
        elif action.action == "notify":
            # macOS 通知
            title = action.params.get("title", "Mac Assistant")
            message = action.params.get("message", "")
            proc = await asyncio.create_subprocess_shell(
                f'osascript -e \'display notification "{message}" with title "{title}"\'',
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            await proc.communicate()
            result["success"] = True
            
        elif action.action == "open_app":
            # 打开应用
            app_name = action.params.get("app", "")
            proc = await asyncio.create_subprocess_shell(
                f'open -a "{app_name}"',
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            await proc.communicate()
            result["success"] = True
            
    except Exception as e:
        result["message"] = str(e)
    
    return result

# ============== API 路由 ==============

@app.get("/")
async def root():
    return {
        "app": APP_NAME,
        "version": VERSION,
        "openclaw": state.openclaw_available,
        "kimi": state.kimi_available
    }

@app.get("/health")
async def health():
    return {
        "status": "ok",
        "openclaw": state.openclaw_available,
        "kimi": state.kimi_available,
        "connections": len(state.active_connections)
    }

@app.post("/chat")
async def chat(message: ChatMessage):
    """处理聊天消息"""
    # 保存历史
    message.timestamp = datetime.now().isoformat()
    state.conversation_history.append(message.dict())
    
    # 调用 AI
    response_text = ""
    
    if state.openclaw_available:
        context = "\n".join([f"{m['role']}: {m['content']}" for m in state.conversation_history[-5:]])
        response_text = await call_openclaw(message.content, context)
    elif state.kimi_available:
        response_text = await call_kimi(message.content)
    else:
        response_text = "❌ 没有可用的 AI 服务"
    
    # 保存响应
    response = ChatMessage(
        role="assistant",
        content=response_text,
        timestamp=datetime.now().isoformat()
    )
    state.conversation_history.append(response.dict())
    
    return response

@app.post("/command")
async def execute_command(request: CommandRequest):
    """执行命令"""
    results = []
    
    if request.use_openclaw and state.openclaw_available:
        result = await call_openclaw(request.command, request.context or "")
        results.append({"source": "openclaw", "content": result})
    
    if request.use_kimi and state.kimi_available:
        result = await call_kimi(request.command)
        results.append({"source": "kimi", "content": result})
    
    return {"results": results}

@app.post("/system")
async def system_action(action: SystemAction):
    """执行系统操作"""
    result = await execute_system_action(action)
    return result

@app.get("/history")
async def get_history(limit: int = 50):
    """获取对话历史"""
    return {"history": state.conversation_history[-limit:]}

@app.delete("/history")
async def clear_history():
    """清空历史"""
    state.conversation_history.clear()
    return {"message": "历史已清空"}

# ============== WebSocket 实时通信 ==============

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    state.active_connections.append(websocket)
    
    try:
        await websocket.send_json({
            "type": "connected",
            "message": f"欢迎使用 {APP_NAME}"
        })
        
        while True:
            data = await websocket.receive_json()
            
            if data.get("type") == "chat":
                # 处理聊天
                prompt = data.get("content", "")
                
                # 调用 AI
                if state.openclaw_available:
                    response = await call_openclaw(prompt)
                elif state.kimi_available:
                    response = await call_kimi(prompt)
                else:
                    response = "❌ 服务不可用"
                
                await websocket.send_json({
                    "type": "response",
                    "content": response
                })
                
            elif data.get("type") == "action":
                # 执行系统操作
                action = SystemAction(**data.get("action", {}))
                result = await execute_system_action(action)
                await websocket.send_json({
                    "type": "action_result",
                    "result": result
                })
                
    except WebSocketDisconnect:
        state.active_connections.remove(websocket)
        print("客户端断开连接")
    except Exception as e:
        print(f"WebSocket 错误: {e}")
        if websocket in state.active_connections:
            state.active_connections.remove(websocket)

# ============== 启动 ==============

if __name__ == "__main__":
    print(f"""
╔══════════════════════════════════════╗
║     {APP_NAME} v{VERSION}            ║
║                                      ║
║  API: http://localhost:{PORT}         ║
║  WebSocket: ws://localhost:{PORT}/ws  ║
╚══════════════════════════════════════╝
    """)
    
    uvicorn.run(
        "main:app",
        host="127.0.0.1",
        port=PORT,
        reload=True,
        log_level="info"
    )
