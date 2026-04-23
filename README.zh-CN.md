# Ask Codex

Ask Codex 是一个非官方 Claude Code skill，用于帮助 Claude Code 将仓库内的实现、探索、验证和代码审查任务委托给 Codex CLI。它提供任务路由规则、单轮委托、broker 多轮会话，以及 Claude Code 与 Codex 协作时的 review loop 约定。

本项目不隶属于 Anthropic 或 OpenAI，也未获得二者官方背书。

English documentation: [README.md](README.md)

## 功能

- 将实现、代码库探索、验证和审查型任务路由给 Codex。
- 提供 `ask_codex.sh` 处理单次 Codex 委托。
- 提供 `codex_broker.sh` 处理长任务或需要中途观察/调整的 Codex 会话。
- 提供 Windows PowerShell 辅助脚本 `ask_codex.ps1`。
- 保持 Claude Code 负责用户沟通、范围控制和最终验证。

## 依赖

- 支持 skill 的 Claude Code。
- 已安装并完成认证的 Codex CLI，命令名为 `codex`。
- `jq`。
- macOS/Linux 使用 `scripts/ask_codex.sh` 和 `scripts/codex_broker.sh` 需要 Bash。
- Windows 可使用 PowerShell 5.1+ 运行 `scripts/ask_codex.ps1`。

## 安装

推荐使用 `skills` CLI 安装：

```bash
npx skills add bookSiYi1412/ask-codex -g -a claude-code
```

手动安装：

```bash
mkdir -p ~/.claude/skills
git clone https://github.com/bookSiYi1412/ask-codex ~/.claude/skills/ask-codex
chmod +x ~/.claude/skills/ask-codex/scripts/*.sh
```

如有需要，重启 Claude Code 以重新加载 skill 元数据。

## Skill 名称

该 skill 名称为 `ask-codex`。

当任务涉及实现、代码库探索、数据或日志检查、大范围搜索、影响面分析、验证密集型 shell 工作，或用户明确要求使用 Codex 时，Claude Code 应触发该 skill。

## Claude Code 使用示例

当你希望 Claude Code 明确把任务交给 Codex 时，可以直接使用 `/ask-codex`。

简单实现任务：

```text
/ask-codex 为用户列表实现分页。保留现有筛选条件，并补充测试。
```

只读代码库探索：

```text
/ask-codex 查找 tenant ID 是在哪里生成和传递的。不要修改文件。用文件路径和命令证据总结发现。
```

多个实现任务并行执行：

```text
/ask-codex 并行启动两个独立的 Codex 任务：
1. 编写 docs/code_architecture.md，说明模块结构、数据流和评估设计。
2. 编写 docs/quickstart_guide.md，给出环境搭建和运行实验的逐步操作指南。

等两个 Codex 任务完成后，统一审查输出质量，再报告结果。
```

长任务或需要中途调整的任务：

```text
/ask-codex 使用 brokered Codex session 实现这次迁移。过程中观察进展，必要时发送后续指令，最后审查 diff。
```

小提示：在 Claude Code 中，如果 Codex 任务以前台方式运行，可以按 `Ctrl+B` 将它切到后台，这样你可以继续处理其他工作。

## 直接使用脚本

单次委托：

```bash
~/.claude/skills/ask-codex/scripts/ask_codex.sh \
  "Add error handling to api.ts" \
  --file src/api.ts
```

只读探索：

```bash
~/.claude/skills/ask-codex/scripts/ask_codex.sh \
  --read-only \
  "Find all call sites for the tenant ID derivation logic"
```

Broker 会话：

```bash
bash ~/.claude/skills/ask-codex/scripts/codex_broker.sh start \
  "Implement the requested change" \
  --file src/main.ts
```

查看 broker 状态：

```bash
bash ~/.claude/skills/ask-codex/scripts/codex_broker.sh status <broker_id>
```

发送后续指令：

```bash
bash ~/.claude/skills/ask-codex/scripts/codex_broker.sh send <broker_id> \
  "Also add validation for the new input."
```

## 运行产物

脚本可能生成本地运行产物：

- `.runtime/`
- `.sessions/`

这些文件可能包含提示词、模型输出、仓库路径和任务细节。它们已被 Git 忽略，不应发布。

## 验证

发布前可以运行轻量检查：

```bash
scripts/check.sh
```

该脚本会执行 Bash 语法检查；如果安装了 `shellcheck`，还会额外运行 shell 静态检查。

## 来源与声明

本项目基于并大幅扩展了 [`oil-oil/codex`](https://github.com/oil-oil/codex)，后者是一个用于把编码任务委托给 Codex CLI 的 Claude Code skill。

本仓库主要增加了更完整的路由规则、broker 会话支持、额外失败处理、开源项目文档和面向发布维护的文件。详细 attribution 见 [NOTICE](NOTICE)。

## 许可证

Apache License 2.0。见 [LICENSE](LICENSE)。
