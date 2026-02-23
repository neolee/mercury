# Mercury

Mercury is a modern, macOS-first RSS reader focused on beautiful reading, speed, and privacy. It aims to make long-form reading pleasant and efficient, while adding practical AI assistance such as tagging, translation, and summarization.

## Highlights
- macOS-first, native SwiftUI experience
- Fast, clean reading with strong typography and keyboard-driven workflows
- Local-first design with optional sync
- AI assistance: auto-tagging, translation, single-article and multi-article summaries
- Privacy and security as default expectations

## Status
This repository is in early design and architecture phase. Details will evolve as the MVP takes shape.

## Contributing
Contributions are welcome once a public test build is available. Until then, feel free to open issues for ideas and feedback.

---

# Mercury

Mercury 是一款 macOS 原生、强调本地优先（*local first*）的 RSS 阅读器，专注于方便舒适的信息聚合与阅读体验，并通过高度可定制的 AI 功能（如文章摘要与双语翻译）提升你的效率（使用任何你能访问的大语言模型，无论本地还是在线服务）。

[![最新版本](https://img.shields.io/github/v/release/neolee/mercury)](https://github.com/neolee/mercury/releases/latest)

---

![Main UI | 主界面](screenshots/mercury-main.png)

![Dark Mode & Themes | 深色模式与主题](screenshots/mercury-theme.png)

![Summary & Translate Agents | 摘要与翻译智能体](screenshots/mercury-agents.png)

![LLM & Agent Settings | 智能体设置](screenshots/mercury-agent-settings.png)

---

## 功能特性

- **原生 macOS 体验**：基于 SwiftUI 构建，遵循 macOS 设计规范，支持键盘驱动操作
- **本地优先**：无需注册，无需登录，无需订阅，永远不会主动采集你的任何数据
- **多格式订阅源**：支持 RSS、Atom、JSON Feed；支持 OPML 批量导入与导出
- **专注阅读**：干净清爽的 Reader 模式提供智能化内容清洗、定制化主题与字体
- **AI 摘要**：一键生成文章摘要，可指定语言和详细程度，支持自定义 Prompt
- **AI 翻译**：将文章翻译为目标语言，原文与译文段落对照显示，支持自定义 Prompt
- **开放、注重隐私的 AI 接入**：兼容任何 OpenAI 格式的 API，包括本地运行和云端运行的各种服务

### 后续功能规划

下列特性正在开发中：

- **界面多语言支持**：应用界面支持多种语言，中文支持将很快发布
- **Token 用量统计**：监控大语言模型的 token 消耗，提供简明扼要的统计记录
- **标签系统**：提供按标签聚合内容的新维度，支持用户自定义标签和 AI 自动打标，可按标签或标签组合筛选文章列表
- **多文章摘要（简报）**：比如针对特定 feed 或标签的新文章生成聚合摘要，快速掌握一段时间内的新内容要点

---

## 系统要求

- macOS 14.6+

如需使用 AI 智能体功能，还需要：

- 一个兼容 OpenAI 格式的 API 访问方案，支持本地和商业化的大语言模型推理服务

---

## 安装

1. 前往 [Releases](https://github.com/neolee/mercury/releases/latest) 页面，下载最新的 `.dmg` 文件
2. 挂载下载的 `.dmg` 文件，将 **Mercury.app** 拖入「应用程序」文件夹
3. 首次启动时 macOS 可能提示来自互联网的应用，点击「打开」即可（应用已经过 Developer ID 签名和 Apple 公证）

---

## 快速上手

### 添加订阅源

- 点击左边栏顶部的 **+** 按钮，选择 **Add Feed…**，输入订阅源 URL，按回车即可添加
- 或选择 **Import OPML…** 并选择你的 OPML 文件来批量导入

### 配置 AI 智能体

Mercury 的摘要和翻译功能由 AI Agent 驱动，使用前需要配置一个大语言模型提供者：

1. 打开 **Mercury → Settings…** 或按快捷键 **command-,**，切换到 **Agents** 标签页
2. 点击 **Providers** 列表底部的 **+** 按钮，填写：
   - **Display Name**：提供者的显示名
   - **Base URL**：OpenAI 兼容的 API 入口地址，例如 `https://api.deepseek.com`，或本地模型如 `http://localhost:2233/v1` 等，注意要包含 API `chat/completions` 之前的所有部分，以及正确的端口
   - **API Key** — 对应服务提供者的密钥（本地模型可填任意字符串），这个密钥仅在你的机器上保存，使用 macOS 的 `keychain` 服务安全存储，不会被 Mercury 以任何形式上传或共享
   - 可以填写该服务提供者的一个模型名（**Test Model**），然后点击 **Test** 按钮来验证配置无误
3. 切换到 **Models** 列表，点击列表底部的 **+** 按钮，选择刚添加的 Provider，填写模型名称，点击 **Test** 按钮验证服务能正常响应
4. 切换到 **Agents** 列表，在 **Summary** 和 **Translation** 的设置页面中，分别选择各自使用的模型，并设置目标语言和其他配置参数

### 使用摘要智能体

打开任意文章，点击文章 Reader 底部的 **Summary** 条展开摘要窗口，确认目标语言和摘要详细程度，点击 **Summary** 按钮，摘要将在下方流式输出。

### 使用翻译智能体

打开文章后，点击主工具条的 **Translate** 按钮，文章将以原文 / 译文段落对照的双语格式呈现，如果对翻译效果不满意，可以点击右边的 **Clear** 按钮清除翻译结果再重新翻译。

### 自定义 Prompts

摘要和翻译智能体各有一套默认 prompts，可在 **Settings** → **Agents** → **Agents** 中选择某个智能体，然后点击 **custom prompts**，Mercury 会定位到对应的 *prompts template*，是一个 YAML 格式的文件，你可以用你选择的编辑器打开它进行定制。如果你想放弃你的定制，仍使用 Mercury 默认的 prompts，直接删除你定制的文件即可。

---

## 隐私

Mercury 遵循本地优先原则：

- 所有订阅数据、阅读状态、摘要和翻译结果均存储在你本机的沙盒数据库中
- 不收集任何使用数据，不与任何第三方共享信息，不需要账号，不需要登录
- AI 请求由你配置的 API 提供者直接处理，Mercury 本身不代理、不记录任何 AI 请求内容

---

## 从源码构建

要求：
- Xcode 16+，macOS 26 SDK
- Swift Package Manager 依赖会在首次构建时自动解析，无需额外操作

```bash
git clone https://github.com/neolee/mercury.git
cd mercury
./scripts/build
```

---

## 问题反馈

如果你在使用中遇到问题，或有功能建议，欢迎通过以下方式反馈：

- **Bug 报告 / 功能建议** — 在 [GitHub Issues](https://github.com/neolee/mercury/issues) 提交，请尽量描述复现步骤、macOS 版本和 Mercury 版本
- **AI 相关问题** — 如果摘要或翻译结果不符合预期，通常可以通过定制 prompts（Settings → Agents → Agents → Custom Prompts）改善；如果是连接或配置问题，请先用设置页面的 **Test** 按钮验证模型可达性

---

## 许可证

本项目基于 [MIT License](LICENSE.md) 发布。
