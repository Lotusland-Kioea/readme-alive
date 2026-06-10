# readme-alive — Keep Your README Alive

**核心承诺：审计 README 准确性，不留下任何工具痕迹。**

一个 Claude Code Skill，自动检测代码与 README 的差异，按严重度分级输出审计报告，支持基于标题的智能段落修复。

## 一句话

你改了代码，readme-alive 帮你检查 README 是否也该更新。

---

## 触发方式

```
/readme-alive                    # 默认：增量审计，自动选择 Tier
/readme-alive --full             # 全量扫描
/readme-alive --fix              # 审计+修复（先展示 diff，等待确认）
/readme-alive --fix --dry-run    # 仅预览修改，不实际执行
/readme-alive --tier 0|1|2       # 强制指定 Agent Tier
/readme-alive --undo             # 回滚到最近一次备份
/readme-alive --undo N           # 回滚到第 N 个备份
/readme-alive --undo --list      # 列出所有备份
/readme-alive --backup "标签"    # 手动创建备份快照
/readme-alive --diff-backup      # 对比当前 README vs 最近备份
```

CLI 独立使用：`bash ~/.claude/skills/readme-alive/cli/readme-alive.sh --check all`

---

## 架构流水线

```
Phase 0: 环境检测 + 复杂度评估（1-10分） → 决定 Tier
         ├── 构建文件检测 → 语言判定
         ├── 纯脚本兜底：无构建文件时按扩展名统计推断语言
         └── 加权公式：文件35%+模块20%+语言20%+项目类型15%+README10%

Phase 1: 弹性审计
         ├── Tier 0（单Agent串行，兜底）
         ├── Tier 1（2Agent并行：Agent A代码扫描 + Agent B README解析）
         └── Tier 2（N Agent扇出，上限8，按Monorepo/多语言/前后端/目录分组）

Phase 2: 风格嗅探 → 交叉验证 → 严重度分级 → 审计报告 → (可选)--fix
```

### 复杂度 → Tier 映射

| 复杂度 | Tier | 说明 |
|--------|------|------|
| 1-3 | Tier 0 | 单 Agent 串行，兜底模式 |
| 4-6 | Tier 1 | 2 Agent 并行，默认级别 |
| 7-10 | Tier 2 | N Agent 扇出，大/Monorepo 项目 |

边界缓冲：raw_score 在 3.0-3.9 或 6.0-6.9 时结合 CI 配置、commit 频率、README 规模辅助判断。

---

## 完整目录结构（22 个文件）

```
readme-alive/
├── README.md                                  # 本文件
├── SKILL.md                                   # Skill 入口定义（约300行，含完整工作流+规则定义）
│
├── cli/
│   └── readme-alive.sh                        # 独立 CLI（约700行，跨平台加固）
│       ├── check: links/sections/files/structure/all
│       ├── complexity: 5语言模块计数+加权评分
│       ├── backup/undo/diff-backup: 双层manifest+原子写入
│       └── --format json: check/complexity 模式支持
│
├── references/
│   ├── readme-spec.md                         # README 质量标准（CNCF/Google/GitHub等9来源共识）
│   ├── complexity-assessment.md               # 复杂度评估算法+边界缓冲
│   ├── audit-dimensions.md                    # 审计维度：4 Critical + 4 Warning + 4 Info + 4项目类型
│   ├── section-detection.md                   # 段落检测+风格继承（关键词权威来源）
│   ├── escalation-strategy.md                 # Agent升级/降级（含Agent B容错+README分块）
│   ├── sampling-strategy.md                   # >5000文件分层优先级抽样
│   └── templates/                             # Greenfield 模板（无HTML注释）
│       ├── web-app.md
│       ├── library.md
│       ├── cli-tool.md
│       └── monorepo.md
│
├── scanners/                                  # 语言扫描规则（插件式，统一结构）
│   ├── java-spring.md                         # Spring Boot（BOM/Gradle/ConfigProperties/Gateway/Security）
│   ├── nodejs.md                              # Node.js（Express/Koa/Fastify/Hono/NestJS/Next.js App Router）
│   ├── python.md                              # Python（FastAPI/Django/Flask/BaseSettings/CLI入口点）
│   ├── go.md                                  # Go（Gin/Echo/Fiber/Chi/Cobra/go.work/构建增强）
│   └── rust.md                                # Rust（Actix/Axum/Rocket/Warp/Poem/Clap/特殊项目类型）
│
├── schemas/
│   ├── audit-report.schema.json               # 审计报告标准格式（JSON Schema 2020-12）
│   ├── agent-a-output.schema.json             # Agent A 代码扫描输出契约
│   └── agent-b-output.schema.json             # Agent B README解析输出契约
│
└── .github/
    └── workflows/
        └── readme-alive.yml.example            # GitHub Action（PR检查+定时周检）
```

---

## 核心特性

### 1. 零痕迹段落识别

利用 README 自身的 H1-H3 标题作为自然边界，通过关键词匹配段落类型。**不插入任何 HTML 注释或标记**，卸载后 README 中无残留。

| 段落类型 | 匹配关键词（中英文并集） |
|---------|----------------------|
| tech-stack | 技术栈/技术选型/依赖/Dependencies/Tech Stack |
| project-structure | 项目结构/目录树/目录/文件结构/Project Structure/Structure |
| interface-overview | API/接口/端点/路由/CLI/子命令/命令/Endpoint/Command/Router |
| quick-start | 快速开始/安装/启动/运行/入门/Getting Started/Quick/Installation |
| config-reference | 配置/环境变量/设置/Configuration/Config/Env |

> 权威来源：`references/section-detection.md`。支持 `.readme-alive-keywords.json` 自定义非中英文关键词。

### 2. 弹性伸缩（借鉴 Java 锁升级）

| Tier | Agent 数 | 适用 | Token | 耗时 |
|------|----------|------|-------|------|
| Tier 0 | 1 | 微型/小型 | 5K-15K | 5-15s |
| Tier 1 | 2 | 中型（默认） | 15K-40K | 10-25s |
| Tier 2 | 3-8 | 大型/Monorepo | 40K-150K | 20-60s |

运行时自动修正：升级（文件数>2倍估计/新发现Monorepo等）+ 降级（≥50%子Agent扫描<30文件等）。

### 3. 五语言深度扫描

每种语言 scanner 遵循统一结构：**检测条件 → 技术栈提取 → API/CLI端点提取 → 配置项提取 → 项目结构 → 已知限制**。

### 4. 风格继承（--fix 模式）

修复生成内容时嗅探并继承用户 README 的排版特征：标题 emoji、表格列数/对齐/列头语言、代码块语言标签、目录树前缀。列数变化时警告询问，不静默修改。

### 5. 回滚系统

- 备份目录：`~/.readme-alive/backups/<project-hash>/`
- 双层 manifest：JSON（jq 可用时）+ 管道分隔文本（兜底，纯 bash）
- 写前必存、回滚可逆（`--undo` 前也备份）、原子写入（`.tmp` + `mv`）
- 保留 20 个备份自动轮转

### 6. 审计报告三级严重度

| 级别 | 含义 | 示例 |
|------|------|------|
| 🔴 Critical | README 声明与代码矛盾 | 依赖版本不匹配、API 路径不存在、链接失效 |
| 🟡 Warning | 代码有但 README 缺 | 新增模块/依赖/配置未在 README 说明 |
| 🔵 Info | 结构改进建议 | 缺少章节、内容应迁移到 CHANGELOG、长度比例 |

---

## 安全规则

不读取以下文件：`.env*`（仅 `.env.example`）、`*.key`、`credentials.*`、`*.pem`、`*.p12`、`secrets.*`、`*.token`、`*.secret`、`privatekey*`、`id_rsa*`、`id_ed25519*`、`id_ecdsa*`、`.npmrc`、`.pypirc`、`.docker/config.json`、`git-credentials`、`*.jks`、`*.keystore`、`*.truststore`、`*.pfx`、`*.pkcs12`、`terraform.tfvars`、`*.auto.tfvars`、`connectionStrings.*`、`appsettings.*.json`、`secret.*`、`private_key*`、`*_rsa`、`*_ed25519`、`*_ecdsa`、`*.kubeconfig`、`*.ovpn`、`.dockercfg`

> **兜底规则**：文件名或路径暗示含凭证/密钥/令牌时，即使不在上述列表中也跳过并记录 WARNING。支持 `.readme-alive-ignore` 文件自定义排除（格式同 `.gitignore`）。

其他：遵守 `.gitignore`、>1MB 文件跳过、>5000 文件采样（分层优先级策略）、所有写操作前自动备份、原子写入防中断。完整安全规则以 SKILL.md 为准。

---

## 设计原则

| 原则 | 说明 |
|------|------|
| 读者优先 | README 的核心读者是第一次接触项目的人 |
| 准确性 > 完整性 | 宁可少写，不可写错 |
| 弹性伸缩 | 小项目轻量跑，大项目自动扩容 |
| 兜底优先 | 任何环境至少以单 Agent 模式工作 |
| 人类终审 | AI 生成 diff，人类决定采纳 |
| 不留痕迹 | 卸载后 README 中无任何残留 |
| 按比例 | README 长度按项目规模判断，不定死数字 |

---

## 开发历程与当前状态

**当前版本：v1.0.0**

| 阶段 | 内容 | 状态 |
|------|------|------|
| Phase 1 | 核心架构 + 2 scanner + 基础 CLI | ✅ |
| Phase 2 | 5 语言全覆盖 + Tier 2 扇出 + Monorepo | ✅ |
| Phase 3 | --fix 段落识别 + 回滚系统 + CLI 增强 | ✅ |
| Phase 3.5 | 11 专家审查（架构/安全/5语言/兜底/复杂度/CLI/Schema） | ✅ |
| Phase 3.6 | 5 scanner 全面增强 + 审查改进阶段（Phase C）P2 改进 | ✅ |
| Phase 4 | 文档完善 + 社区发布（2026-06-10 审查改进中） | 🔄 |

### 审查统计（2026-06-04）

- 11 位专家并行审查：架构设计、安全权限、Java/Python/Go/Rust/Node.js 扫描器、兜底策略、复杂度评估、CLI/CI 双形态、Schema/模板
- 全量发现：45 Critical + 86 Warning
- 三轮修复（P0→P1→P2）：全部清零

> **注**：以上为内部审查数据（审查报告存档于项目文档）。2026-06-10 进行了第二轮全量审查（Phase A-D），修复结果见本文档各修复项。

### 审查改进阶段（Phase C = 代码审查驱动的质量改进）关键改进

- 复杂度权重微调（减少文件数与模块数重叠）
- Tier 边界缓冲区（辅助信号二次判断）
- 大项目分层抽样策略（`references/sampling-strategy.md`）
- Agent B 超时降级 + README 分块解析
- 非中英文自定义关键词（`.readme-alive-keywords.json`）
- 非 Git 环境文件快照伪增量
- Greenfield 草稿补充"贡献指南"
- 纯脚本项目扩展名兜底检测

---

## 不支持的语言 & 降级行为

- 语言不在 5 种内置中：跳过深度扫描，仍执行通用审计（结构/章节/链接/长度），标注 `[Generic Audit]`
- `--fix` 段落识别和风格继承仍工作
- 纯脚本项目：按扩展名统计推断主语言，标注 `[Inferred]`
- 非中英文 README：优先英文关键词 → 追加模式 → 可自定义关键词文件
- 非 Git 环境：全量扫描 + 伪增量快照（可选）

---

## 已知限制

每个 scanner 文件中均包含"未覆盖场景（已知限制）"章节，主要包括：

- gRPC 服务定义提取（`.proto`）在各语言中部分支持
- 非主流 Web/CLI 框架检测覆盖率有限
- 外部配置源（Config Server / Consul / Vault）未审计
- 非中英文 README 段落关键词仅支持英文 fallback + 自定义扩展
- CLI `--format json` 仅支持 check 和 complexity 模式（完整 AI 功能需 Claude Code）
- GOPATH 模式 Go 项目无法通过模块检测（仅有信号识别）
- Python 纯脚本项目检测依赖扩展名推断，不如构建文件准确

---

## 竞品对比

| 维度 | readme-alive | rereadme | code-documents-auto-skill |
|------|-------------|----------|--------------------------|
| 弹性伸缩 | Tier 0→2 自动+手动 | 固定 | - |
| 不留痕迹 | 零标记（段落检测） | - | 锚点污染 |
| 多语言插件 | 5 语言+已知限制 | 通用 LLM | 部分 |
| 风格继承 | emoji/列数/对齐/语言 | - | - |
| 回滚系统 | 备份链+原子写入+双层manifest | - | - |
| CI/CLI | Skill+CLI 双形态 | CI 模式 | - |
| 人类终审 | 强制 diff→确认 | 可选 | 全自动 |
| 数据契约 | Agent A/B 输出 JSON Schema | - | - |
| 大项目 | 分层采样+伪增量 | - | - |

> **注**：readme-alive 在 v1.0.0 版本已从 HTML 锚点系统迁移到零痕迹段落检测。旧版本（<v1.0.0-rc）存在类似锚点残留问题。

## 许可证

MIT
