# OpenClaw Core 管理指南

## 概述

本项目使用 **Fork 模式** 管理 `openclaw-core` 子模块，以支持自定义修改的同时保持与上游同步。

## 仓库结构

```
mac-assistant/
├── openclaw-core/          # 子模块（指向我们的 fork）
│   ├── origin:  https://github.com/superkonka/openclaw.git (我们的 fork)
│   └── upstream: https://github.com/openclaw/openclaw.git (原始仓库)
│   ├── main:                # 跟踪上游，保持干净
│   └── mac-assistant-custom: # 我们的自定义修改分支
└── .gitmodules              # 子模块配置
```

## 分支说明

### openclaw-core 内部的分支

| 分支 | 用途 | 同步策略 |
|------|------|----------|
| `main` | 跟踪上游 openclaw 最新版本 | 定期从 upstream/main 拉取 |
| `mac-assistant-custom` | 保存我们的自定义修改 | 基于 main，定期合并 main 的更新 |

## 常用操作

### 1. 同步上游更新到 main

```bash
cd openclaw-core
git checkout main
git fetch upstream
git merge upstream/main
git push origin main
```

### 2. 更新主项目使用的 openclaw-core 版本

```bash
# 更新到 main 最新版本
cd openclaw-core
git checkout main
git pull origin main
cd ..
git add openclaw-core
git commit -m "chore: 更新 openclaw-core 到最新版本"
git push
```

### 3. 合并上游更新到自定义分支

```bash
cd openclaw-core
git checkout mac-assistant-custom
git merge main  # 可能需要解决冲突
git push origin mac-assistant-custom
```

### 4. 添加新的自定义修改

```bash
cd openclaw-core
git checkout mac-assistant-custom
# 进行修改...
git add .
git commit -m "feat: 描述你的修改"
git push origin mac-assistant-custom

# 如果需要应用到主项目当前使用的版本
git checkout main
git cherry-pick mac-assistant-custom  # 或者手动应用修改
git push origin main
cd ..
git add openclaw-core
git commit -m "chore: 应用 openclaw-core 自定义修改"
```

## 首次设置（已配置完成）

以下步骤已完成，仅供参考：

```bash
# 1. Fork 原始仓库（在 GitHub 网页上完成）
# https://github.com/openclaw/openclaw/fork

# 2. 修改 .gitmodules
cat .gitmodules
# [submodule "openclaw-core"]
#     path = openclaw-core
#     url = https://github.com/superkonka/openclaw.git

# 3. 更新子模块远程 URL
cd openclaw-core
git remote set-url origin https://github.com/superkonka/openclaw.git
git remote add upstream https://github.com/openclaw/openclaw.git

# 4. 创建并推送自定义分支
git checkout -b mac-assistant-custom
git push -u origin mac-assistant-custom
```

## 注意事项

1. **不要直接修改 `main` 分支** - 这是用于跟踪上游的干净分支
2. **自定义修改放在 `mac-assistant-custom` 分支** - 并定期合并 main 的更新
3. **主项目引用特定的 commit** - 通过 `git add openclaw-core` 来更新
4. **及时同步上游更新** - 避免积累太多冲突

## 故障排除

### 子模块无法拉取

```bash
git submodule sync  # 同步 .gitmodules 配置
git submodule update --init --recursive
```

### 权限错误

确保 fork 的仓库是公开的，或者你有正确的访问权限。

### 冲突解决

当 `mac-assistant-custom` 与 `main` 冲突时：

```bash
cd openclaw-core
git checkout mac-assistant-custom
git merge main
# 解决冲突...
git add .
git commit
git push origin mac-assistant-custom
```
