"""
Kimi AI Provider - 支持 CLI 和 API Key 两种方式
"""

import os
import json
import asyncio
import subprocess
from typing import Optional, List, Dict, Any, AsyncGenerator
from dataclasses import dataclass, asdict
from pathlib import Path

import aiohttp


@dataclass
class KimiConfig:
    """Kimi 配置"""
    provider: str = "cli"  # "cli" 或 "api"
    api_key: str = ""
    api_base: str = "https://api.moonshot.cn/v1"
    model: str = "moonshot-v1-8k"
    timeout: int = 60
    
    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> 'KimiConfig':
        return cls(**{k: v for k, v in data.items() if k in cls.__dataclass_fields__})


class KimiProvider:
    """Kimi AI 提供者 - 支持 CLI 和 API Key"""
    
    def __init__(self):
        self.config = self._load_config()
        self._cli_available: Optional[bool] = None
        self._api_available: Optional[bool] = None
    
    def _get_config_path(self) -> Path:
        """获取配置文件路径"""
        config_dir = Path.home() / ".config" / "mac-assistant"
        config_dir.mkdir(parents=True, exist_ok=True)
        return config_dir / "kimi_config.json"
    
    def _load_config(self) -> KimiConfig:
        """加载配置"""
        config_path = self._get_config_path()
        if config_path.exists():
            try:
                with open(config_path, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                return KimiConfig.from_dict(data)
            except Exception as e:
                print(f"⚠️ 加载 Kimi 配置失败: {e}")
        return KimiConfig()
    
    def save_config(self) -> bool:
        """保存配置"""
        try:
            config_path = self._get_config_path()
            with open(config_path, 'w', encoding='utf-8') as f:
                json.dump(self.config.to_dict(), f, indent=2, ensure_ascii=False)
            return True
        except Exception as e:
            print(f"❌ 保存 Kimi 配置失败: {e}")
            return False
    
    async def check_cli_available(self) -> bool:
        """检查 Kimi CLI 是否可用"""
        if self._cli_available is not None:
            return self._cli_available
        
        try:
            proc = await asyncio.create_subprocess_exec(
                "kimi", "--version",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=5)
            self._cli_available = proc.returncode == 0
        except Exception:
            self._cli_available = False
        
        return self._cli_available
    
    async def check_api_available(self) -> bool:
        """检查 Kimi API 是否可用（有有效的 API Key）"""
        if self._api_available is not None:
            return self._api_available
        
        if not self.config.api_key:
            self._api_available = False
            return False
        
        try:
            headers = {
                "Authorization": f"Bearer {self.config.api_key}",
                "Content-Type": "application/json"
            }
            
            async with aiohttp.ClientSession() as session:
                async with session.get(
                    f"{self.config.api_base}/models",
                    headers=headers,
                    timeout=aiohttp.ClientTimeout(total=10)
                ) as resp:
                    self._api_available = resp.status == 200
        except Exception:
            self._api_available = False
        
        return self._api_available
    
    async def get_available_providers(self) -> Dict[str, bool]:
        """获取所有可用的提供者"""
        cli = await self.check_cli_available()
        api = await self.check_api_available()
        return {
            "cli": cli,
            "api": api,
            "current": self.config.provider if (cli and self.config.provider == "cli") or (api and self.config.provider == "api") else ("cli" if cli else ("api" if api else None))
        }
    
    async def chat(self, prompt: str, files: List[str] = None, stream: bool = False) -> str:
        """
        发送聊天请求
        
        Args:
            prompt: 用户输入
            files: 附件文件路径列表
            stream: 是否流式响应
        
        Returns:
            AI 回复内容
        """
        # 根据配置选择提供者
        if self.config.provider == "api" and await self.check_api_available():
            if stream:
                # 流式响应需要特殊处理，这里先返回完整响应
                full_response = ""
                async for chunk in self._chat_api_stream(prompt, files):
                    full_response += chunk
                return full_response
            else:
                return await self._chat_api(prompt, files)
        
        elif await self.check_cli_available():
            return await self._chat_cli(prompt, files)
        
        else:
            return "❌ Kimi 服务不可用。请在设置中配置 Kimi CLI 或 API Key。"
    
    async def _chat_cli(self, prompt: str, files: List[str] = None) -> str:
        """使用 Kimi CLI 聊天"""
        cmd = ["kimi", "-p", prompt]
        if files:
            for f in files:
                cmd.extend(["-f", f])
        
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            stdout, stderr = await asyncio.wait_for(
                proc.communicate(), 
                timeout=self.config.timeout
            )
            
            if proc.returncode == 0:
                return stdout.decode().strip()
            else:
                error_msg = stderr.decode().strip()
                if "rate limit" in error_msg.lower():
                    return "⚠️ Kimi CLI 请求频率限制，请稍后再试"
                return f"⚠️ Kimi CLI 错误: {error_msg}"
                
        except asyncio.TimeoutError:
            return "⏱️ Kimi CLI 请求超时"
        except Exception as e:
            return f"❌ Kimi CLI 调用失败: {str(e)}"
    
    async def _chat_api(self, prompt: str, files: List[str] = None) -> str:
        """使用 Kimi API 聊天"""
        try:
            headers = {
                "Authorization": f"Bearer {self.config.api_key}",
                "Content-Type": "application/json"
            }
            
            # 构建消息
            messages = [{"role": "user", "content": prompt}]
            
            # 如果有文件，读取内容
            if files:
                file_contents = []
                for file_path in files:
                    try:
                        with open(file_path, 'r', encoding='utf-8') as f:
                            content = f.read()
                            file_contents.append(f"File: {file_path}\n```\n{content}\n```")
                    except Exception as e:
                        file_contents.append(f"File: {file_path}\nError reading: {e}")
                
                if file_contents:
                    messages[0]["content"] = "\n\n".join(file_contents) + "\n\n" + prompt
            
            payload = {
                "model": self.config.model,
                "messages": messages,
                "temperature": 0.7,
                "stream": False
            }
            
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    f"{self.config.api_base}/chat/completions",
                    headers=headers,
                    json=payload,
                    timeout=aiohttp.ClientTimeout(total=self.config.timeout)
                ) as resp:
                    if resp.status == 200:
                        data = await resp.json()
                        return data['choices'][0]['message']['content']
                    elif resp.status == 401:
                        return "❌ Kimi API Key 无效，请检查配置"
                    elif resp.status == 429:
                        return "⚠️ Kimi API 请求频率限制，请稍后再试"
                    else:
                        error_text = await resp.text()
                        return f"⚠️ Kimi API 错误 (HTTP {resp.status}): {error_text}"
                        
        except asyncio.TimeoutError:
            return "⏱️ Kimi API 请求超时"
        except Exception as e:
            return f"❌ Kimi API 调用失败: {str(e)}"
    
    async def _chat_api_stream(self, prompt: str, files: List[str] = None) -> AsyncGenerator[str, None]:
        """使用 Kimi API 流式聊天"""
        try:
            headers = {
                "Authorization": f"Bearer {self.config.api_key}",
                "Content-Type": "application/json"
            }
            
            messages = [{"role": "user", "content": prompt}]
            
            if files:
                file_contents = []
                for file_path in files:
                    try:
                        with open(file_path, 'r', encoding='utf-8') as f:
                            content = f.read()
                            file_contents.append(f"File: {file_path}\n```\n{content}\n```")
                    except Exception as e:
                        file_contents.append(f"File: {file_path}\nError reading: {e}")
                
                if file_contents:
                    messages[0]["content"] = "\n\n".join(file_contents) + "\n\n" + prompt
            
            payload = {
                "model": self.config.model,
                "messages": messages,
                "temperature": 0.7,
                "stream": True
            }
            
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    f"{self.config.api_base}/chat/completions",
                    headers=headers,
                    json=payload,
                    timeout=aiohttp.ClientTimeout(total=self.config.timeout)
                ) as resp:
                    if resp.status == 200:
                        async for line in resp.content:
                            line = line.decode('utf-8').strip()
                            if line.startswith('data: '):
                                data_str = line[6:]
                                if data_str == '[DONE]':
                                    break
                                try:
                                    data = json.loads(data_str)
                                    delta = data['choices'][0]['delta']
                                    if 'content' in delta:
                                        yield delta['content']
                                except (json.JSONDecodeError, KeyError):
                                    pass
                    else:
                        error_text = await resp.text()
                        yield f"⚠️ Kimi API 错误 (HTTP {resp.status}): {error_text}"
                        
        except Exception as e:
            yield f"❌ Kimi API 流式调用失败: {str(e)}"


# 全局 Kimi 提供者实例
kimi_provider = KimiProvider()
