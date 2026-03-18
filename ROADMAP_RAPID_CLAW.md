# Rapid Claw Capabilities - 功能迭代路线图

> **分支**: `feature/rapid-claw-capabilities`  
> **目标**: 让 Mac Assistant 成为快速使用 Claw 能力的智能编排器  
> **愿景**: 从"Claw 的客户端"进化为"Claw 能力的智能入口"

---

## 📋 背景

OpenClaw 最新版本带来了大量新能力：
- Bundles (Codex/Claude/Cursor)
- Plugin 生态 (Firecrawl、图片生成等)
- 快速提问模式 (`/btw`)
- SSH/OpenShell Sandbox
- 交互式消息
- 扩展诊断工具

当前 Mac Assistant 未能充分利用这些能力，用户仍需手动配置多个 Agent 才能使用。

---

## 🎯 核心目标

1. **Bundle 一键配置** - 告别手动 Agent 配置
2. **快速提问模式** - `/btw` 式的即时问答
3. **Plugin 生态对接** - 浏览、安装、管理 OpenClaw 插件
4. **智能意图识别** - 自动推荐最佳配置

---

## 🗓️ 迭代计划

### Phase 1: Bundle 支持 (P0) - 第 1-2 周

**目标**: 支持一键安装和使用 OpenClaw Bundles

#### 任务清单

- [ ] **1.1 Bundle 服务层**
  - 创建 `BundleService.swift`
  - 封装 `openclaw bundle` 命令调用
  - 支持 list/search/install/uninstall 操作

- [ ] **1.2 Bundle 数据模型**
  - 创建 `BundleModels.swift`
  - 定义 Bundle 元数据结构
  - 支持 Codex/Claude/Cursor 等类型

- [ ] **1.3 Bundle 管理界面**
  - 创建 `BundleStoreView.swift`
  - 浏览可用 Bundles
  - 显示 Bundle 详情和依赖
  - 一键安装/卸载

- [ ] **1.4 智能 Bundle 推荐**
  - 基于用户意图推荐 Bundle
  - "我想写代码" → 推荐 Claude/Codex Bundle
  - "帮我搜索资料" → 推荐 Firecrawl Bundle

- [ ] **1.5 Bundle 配置迁移**
  - 安装 Bundle 后自动配置 Agent
  - 替换手动 Provider + Model 配置

#### 验收标准
```
用户: "我想用 Claude 来编程"
系统: 自动安装 Claude Bundle → 创建 Coding Agent → 配置 SSH Sandbox
用户: 立即可用
```

---

### Phase 2: 快速提问模式 (P0) - 第 2-3 周

**目标**: 实现类似 `/btw` 的快速问答，不污染主会话上下文

#### 任务清单

- [ ] **2.1 快速模式架构**
  - 创建 `QuickQueryService.swift`
  - 支持快速模式与完整模式切换
  - 快速模式不保存历史

- [ ] **2.2 UI 改造**
  - ChatView 支持模式切换
  - 快速模式：简洁输入框，无历史显示
  - 完整模式：现有对话流

- [ ] **2.3 快捷键支持**
  - `Cmd+Shift+Enter` 快速提问
  - 菜单栏快速输入窗口
  - Spotlight 式快速搜索

- [ ] **2.4 上下文隔离**
  - 快速模式使用独立 Session
  - 不影响主会话的上下文
  - 回答后自动清理

- [ ] **2.5 快速工具调用**
  - "搜索 xxx" → 直接调用 web_search
  - "截图问" → 直接调用 vision
  - 无需等待 Planner 决策

#### 验收标准
```
用户: Cmd+Shift+Enter → "Python 的列表推导式怎么用？"
系统: 快速回答 → 关闭后不影响主对话
```

---

### Phase 3: Plugin 生态对接 (P1) - 第 3-4 周

**目标**: 支持浏览、安装、管理 OpenClaw 插件

#### 任务清单

- [ ] **3.1 Plugin 服务层**
  - 创建 `PluginStoreService.swift`
  - 封装 `openclaw plugins` 命令
  - 支持 inspect/list/install/uninstall

- [ ] **3.2 Plugin 市场界面**
  - 创建 `PluginStoreView.swift`
  - 分类浏览（Provider、Channel、Tool）
  - 搜索和筛选
  - 显示 Plugin 能力和兼容性

- [ ] **3.3 Plugin 管理**
  - 已安装 Plugin 列表
  - 启用/禁用 Plugin
  - Plugin 配置界面

- [ ] **3.4 热门 Plugin 支持**
  - **Firecrawl**: 搜索和抓取
  - **图片生成**: 集成 image_generate 工具
  - **Chutes**: 新 Provider 支持

- [ ] **3.5 Plugin 自动更新**
  - 检测 Plugin 更新
  - 一键更新所有
  - 更新前兼容性检查

#### 验收标准
```
用户: 打开 Plugin Store → 搜索 "Firecrawl" → 安装
系统: 安装成功 → 可用 firecrawl_search 工具
```

---

### Phase 4: 图片生成工具 (P1) - 第 4-5 周

**目标**: 集成 OpenClaw 的 image_generate 工具

#### 任务清单

- [ ] **4.1 图片生成服务**
  - 创建 `ImageGenerationService.swift`
  - 调用 `image_generate` 工具
  - 支持多种 provider (OpenAI, Google 等)

- [ ] **4.2 图片生成界面**
  - 创建 `ImageGenerationView.swift`
  - 输入提示词
  - 选择风格和尺寸
  - 显示生成进度

- [ ] **4.3 自然语言触发**
  - "画一只猫" → 自动触发图片生成
  - 生成结果直接嵌入对话

- [ ] **4.4 图片管理**
  - 保存生成的图片
  - 历史记录
  - 重新生成/变体

#### 验收标准
```
用户: "画一只在月球上的宇航员猫咪"
系统: 显示生成进度 → 展示图片 → 可保存
```

---

### Phase 5: Sandbox 支持 (P2) - 第 5-6 周

**目标**: 支持 SSH/OpenShell Sandbox 安全执行

#### 任务清单

- [ ] **5.1 Sandbox 配置**
  - 创建 `SandboxConfigurationView.swift`
  - 配置 SSH 密钥/密码
  - 选择 Sandbox 类型 (SSH/OpenShell/Docker)

- [ ] **5.2 代码执行**
  - 在 Sandbox 中执行代码
  - 显示执行结果
  - 错误处理和日志

- [ ] **5.3 安全策略**
  - 执行前确认
  - 允许列表配置
  - 超时和资源限制

#### 验收标准
```
用户: "帮我运行这段 Python 代码"
系统: 在配置的 Sandbox 中执行 → 返回结果
```

---

### Phase 6: 交互式消息 (P2) - 第 6-7 周

**目标**: 支持渲染 OpenClaw 的交互式消息（按钮、卡片）

#### 任务清单

- [ ] **6.1 消息渲染引擎**
  - 升级 `RichTextView`
  - 支持交互式组件解析

- [ ] **6.2 按钮组件**
  - 渲染内联按钮
  - 处理点击事件
  - 回调到 Claw

- [ ] **6.3 卡片组件**
  - 渲染结构化卡片
  - 支持头部、内容、操作区

- [ ] **6.4 交互式表单**
  - 输入框、选择器
  - 提交和验证

#### 验收标准
```
Claw: 发送带按钮的消息
Mac Assistant: 正确渲染按钮 → 用户点击 → 正确回调
```

---

### Phase 7: 智能诊断 (P2) - 第 7-8 周

**目标**: 增强诊断和自愈能力

#### 任务清单

- [ ] **7.1 诊断工具升级**
  - 集成 `openclaw doctor --fix`
  - 扩展内存分析
  - Plugin 健康检查

- [ ] **7.2 自动修复**
  - 检测常见问题
  - 一键修复
  - 修复前备份

- [ ] **7.3 性能监控**
  - 实时内存使用
  - Gateway 状态监控
  - 慢查询检测

---

## 🏗️ 架构调整

### 新增核心服务

```
Services/
├── BundleService.swift          # Bundle 管理
├── QuickQueryService.swift      # 快速提问
├── PluginStoreService.swift     # Plugin 商店
├── ImageGenerationService.swift # 图片生成
├── SandboxService.swift         # Sandbox 管理
└── IntelligentOnboarding.swift  # 智能配置
```

### 新增视图

```
Views/
├── BundleStore/
│   ├── BundleStoreView.swift
│   ├── BundleCard.swift
│   └── BundleDetailView.swift
├── PluginStore/
│   ├── PluginStoreView.swift
│   ├── PluginCard.swift
│   └── PluginDetailView.swift
├── QuickMode/
│   ├── QuickQueryView.swift
│   └── QuickInputWindow.swift
└── ImageGen/
    ├── ImageGenerationView.swift
    └── ImageGalleryView.swift
```

---

## 🎯 关键成功指标

| 指标 | 目标 | 衡量方式 |
|------|------|---------|
| Bundle 安装时间 | < 30 秒 | 从点击安装到可用 |
| 快速提问响应 | < 3 秒 | 从输入到开始响应 |
| Plugin 发现时间 | < 5 秒 | 搜索到结果展示 |
| 图片生成时间 | < 30 秒 | 从提示到图片显示 |
| 配置步骤减少 | -80% | 对比手动 Agent 配置 |

---

## 📝 开发规范

### 分支策略
```
feature/rapid-claw-capabilities  (主开发分支)
  ├── feature/bundle-service
  ├── feature/quick-query
  ├── feature/plugin-store
  └── feature/image-generation
```

### 提交规范
```
feat(bundle): 添加 BundleService 基础实现
feat(quick): 实现快速提问模式
feat(plugin): 添加 PluginStoreView
fix(image): 修复图片生成超时问题
docs(roadmap): 更新迭代计划
```

### 测试要求
- 每个服务类必须有单元测试
- UI 组件必须有预览和快照测试
- 集成测试覆盖主要用户流程

---

## 🚀 快速启动

### 开始 Phase 1

```bash
# 1. 确认在正确的分支
git checkout feature/rapid-claw-capabilities

# 2. 创建功能分支
git checkout -b feature/bundle-service

# 3. 开始开发...
# 编辑 Services/BundleService.swift

# 4. 提交
git add .
git commit -m "feat(bundle): 添加 BundleService 基础实现"
git push origin feature/bundle-service

# 5. 完成后合并回主开发分支
git checkout feature/rapid-claw-capabilities
git merge feature/bundle-service
git push origin feature/rapid-claw-capabilities
```

---

## 📞 协作方式

- **每日站会**: 同步进度和阻塞
- **周回顾**: 检查里程碑完成情况
- **PR 审查**: 所有代码必须通过审查
- **文档同步**: 功能开发同时更新文档

---

**让我们开始构建下一代 Mac Assistant！** 🚀
