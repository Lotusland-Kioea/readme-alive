---
name: readme-alive
version: "1.0.0"
description: >
  审计 README 与代码的一致性，按严重度分级输出差异报告。
  支持弹性 Agent 伸缩（Tier 0→1→2）、5 种语言深度扫描、基于标题的智能段落修复。
  当用户需要检查 README 是否过时、代码变更后同步 README、或从零生成 README 时使用。
  不在用户 README 中留下任何工具标记或注释。
disable-model-invocation: true
arguments: [mode]
argument-hint: "[--fix | --full | --undo | --backup [label] | --diff-backup | --tier 0|1|2]"
---

# readme-alive — Keep Your README Alive

**核心承诺：审计 README 准确性，不留下任何工具痕迹。**

## 触发

```
/readme-alive                    # 默认：增量审计，自动选择 Tier
/readme-alive --full             # 全量扫描
/readme-alive --fix              # 审计+修复（先展示diff，等待确认）
/readme-alive --fix --dry-run    # 仅预览修改，不实际执行
/readme-alive --tier 0|1|2       # 强制指定 Agent Tier
/readme-alive --undo             # 回滚到最近一次备份
/readme-alive --undo 3           # 回滚到第 N 个备份
/readme-alive --undo --list      # 列出所有备份
/readme-alive --backup           # 手动创建备份快照
/readme-alive --backup "描述"    # 带标签的手动备份
/readme-alive --diff-backup      # 对比当前 README vs 最近备份
```

## 核心工作流

### Phase 0：环境检测与复杂度评估

主 Agent 直接执行（< 5 秒）。详见 `references/complexity-assessment.md`。

```
1. 环境检测：
   - README.md 是否存在？（不存在 → 跳转至「无 README 基线（Greenfield 模式）」段落）
   - Git 仓库是否可用？
   - 多 Agent 平台是否支持？
   
2. 项目类型检测：
   - 语言 (Java/Node.js/Python/Go/Rust/其他)
   - 类型 (Web应用/CLI/库/Monorepo)
   - **纯脚本兜底**：当所有构建文件检测均失败时，按文件扩展名统计（`.py`/`.sh`/`.js`/`.rb` 等），以数量最多的扩展名推断主语言，标注 `[Inferred: Python, confidence=40%]`（含置信度百分比）。最高扩展名占比 <50% 时，自动限制为 Tier 0 且仅执行通用审计
   - **步骤2产出语言列表供步骤3消费，避免重复检测**
   
3. 复杂度评估 (1-10分)：
   文件数(35%) + 模块数(20%) + 语言数(20%) + 项目类型(15%) + README规模(10%)
     → 1-3 分 → Tier 0（单 Agent）
     → 4-6 分 → Tier 1（2 Agent 并行，默认）
     → 7-10分 → Tier 2（N Agent 扇出）
     
4. 扫描策略：
   - Git 可用 + 非 --full → 增量（git diff HEAD~10）
   - Git 不可用 或 --full → 全量
```

手动 `--tier N` 覆盖自动评估。`--tier N` 仅跳过自动复杂度评分（步骤3），环境检测（步骤1-2）和扫描策略选择（步骤4）始终执行。审计报告 metadata 中 tierReason 标注 `manual:TierN`，格式为 `[manual]TierN:correctionTimestamp`（correctionTimestamp 为 ISO 8601 时间戳）。所有 Tier 均可自动降级到 Tier 0，审计结果不受影响。

### Phase 1：弹性审计

README 不存在时 Agent B 自动跳过（所有 Tier），仅 Agent A 执行代码扫描。

#### Tier 0（单 Agent 串行，兜底模式）

按以下顺序串行：
1. 检测项目类型和语言特征
2. 从 `scanners/` 按需加载匹配的语言规则文件
3. 扫描代码：目录结构、依赖/版本、API 端点、配置项
4. 解析 README（如存在）：章节结构、声明的技术栈/API/文件引用/命令
5. 交叉验证 → 生成审计报告

#### Tier 1（2 Agent 并行，默认）

**Agent A — 代码全景扫描**：
- 继承 Phase 0 的语言/类型检测结果，按需加载对应 scanner，随后做深度确认
- 从 `scanners/` 加载匹配的语言规则（只加载项目使用的语言，不加载全部）
- 构建项目结构树（排除 node_modules/.git/target/vendor/__pycache__ 等）
- 提取技术栈清单（直接依赖 + 版本号）
- 提取对外接口（Web API / CLI 子命令 / 库导出符号）
- 提取配置项（环境变量、配置文件 key）
- 返回结构化 JSON

**Agent B — README 解析**（README 不存在时跳过）：
- 解析 README 的 Markdown 标题树（H1-H3）
- 提取 README 中声明的技术栈及其版本
- 提取 README 中列出的目录/文件路径引用
- 提取 README 中的接口描述（API/CLI/导出符号）
- 提取 README 中的可执行命令（安装/启动/测试）
- 识别可能过时或放错位置的内容
- 检查内部链接有效性
- 返回结构化 JSON

#### Tier 2（N Agent 扇出）

代码扫描侧按项目结构动态拆分，Agent B 始终为 1 个。详见 `references/escalation-strategy.md`。

**Agent B 超时降级**：当 Agent B（README 解析）超时时自动降级 Tier，tierReason 格式为 `[auto→T2→B超时]T1:correctionTimestamp`。降级时在终端输出末尾明确打印可操作建议（如"请拆分 README 后重试"），而非仅写入 JSON metadata。

#### Scanner 结构契约

每个 `scanners/` 下的语言/框架 scanner 文件必须包含以下 6 个章节（MUST），额外章节为 MAY 扩展：

1. **检测条件** (Detection Conditions) — MUST：定义该 scanner 的触发规则（如文件特征、构建文件存在性）
2. **技术栈提取** (Tech Stack Extraction) — MUST：依赖文件解析规则、版本号提取方式
3. **API/CLI端点提取** (API/CLI Endpoint Extraction) — MUST：路由定义、CLI 子命令、导出符号的扫描规则
4. **配置项提取** (Configuration Extraction) — MUST：环境变量、配置文件 key 的提取规则
5. **项目结构** (Project Structure) — MUST：该语言/框架的标准目录布局描述
6. **已知限制** (Known Limitations) — MUST：该 scanner 无法覆盖的边缘情况

MAY 扩展章节示例：gRPC/GraphQL 检测、构建/安装方式、包管理器检测、测试框架检测、ORM/数据库迁移检测。

### Phase 2：综合与报告

1. **风格嗅探**（`--fix` 模式专属步骤）：
   - 检测 README 的标题风格（emoji 前缀、语言偏好、标题层级）
   - 检测表格格式（列数、列头语言、对齐方式）
   - 检测代码块格式（语言标签、缩进习惯）
   - 生成内容时**严格继承**检测到的风格

2. **交叉验证**：Agent A 的代码实际 vs Agent B 的 README 声明（如 README 不存在，只输出正向枚举报告）

3. **严重度分级**（详见 `references/audit-dimensions.md`）：
   - 🔴 Critical：README 声明与代码矛盾
   - 🟡 Warning：代码有但 README 缺
   - 🔵 Info：结构建议

4. **生成审计报告**（格式见 `schemas/audit-report.schema.json`）

5. **（可选）`--fix` 模式**：基于标题的自然段落边界智能修复
6. **输出 Token 消耗摘要**

---

## 基于标题的段落识别（替代锚点系统）

**设计哲学**：利用用户 README 自身的标题结构作为自然边界，不插入任何标记。

### 段落识别规则

在 `--fix` 模式下，主 Agent 解析 README 的 H1-H3 标题，按关键词匹配段落类型：

```
标题含"技术栈|技术选型|依赖|Dependencies|Tech Stack"              → tech-stack
标题含"项目结构|目录树|目录|文件结构|Project Structure|Structure"  → project-structure  
标题含"API|接口|端点|路由|CLI|子命令|命令|Endpoint|Command|Router" → interface-overview
标题含"快速开始|安装|启动|运行|入门|Getting Started|Quick|Installation" → quick-start
标题含"配置|环境变量|设置|Configuration|Config|Env"               → config-reference
```

> 完整关键词定义与优先级规则见 `references/section-detection.md`（权威来源）。

- 匹配时同时检查中英文关键词，**以 README 正文语言为主要依据**（中文占比>50%用中文列头）
- 一个标题匹配到多种类型时，选优先级最高的（列表顺序=优先级）
- 一个类型匹配到多个标题时，选匹配度最高的
- 完全没有匹配的标题对应的段落保留不动
- **非中英文 README（日语/韩语/法语等）**：优先尝试英文关键词匹配；如无匹配，退化为"追加模式"（在 README 末尾追加建议章节而非修改现有段落）
- **用户自定义关键词**：支持项目根目录放置 `.readme-alive-keywords.json` 文件，为非中英文项目自定义标题关键词映射。格式：
  ```json
  {
    "tech-stack": ["技術スタック", "Technologies", "기술 스택"],
    "project-structure": ["構成", "ディレクトリ構成"],
    "interface-overview": ["API一覧", "コマンド"],
    "quick-start": ["はじめに", "セットアップ", "시작하기"],
    "config-reference": ["設定", "環境変数", "환경 설정"]
  }
  ```
  文件存在时，自定义关键词与内置中英文关键词合并使用。文件不存在不做任何操作（零配置开销）。

### `--fix` 执行流程（不留痕迹版）

1. **前置审计**（Phase 0→1→2）
2. **风格嗅探**：记录当前 README 的排版特征
3. **自动备份**：`README.md` → `~/.readme-alive/backups/{project}/{ts}_before-fix.md`
4. 解析标题树，识别每个标题对应的段落类型
5. 生成修改预览（diff 格式），标注每个段落的变更内容
6. **强制等待用户确认**（`--dry-run` 在此步停止，不执行实际修改）：
   - 展示每个段落的 before/after diff
   - 标注哪些段落会被修改、哪些保留不动
   - 用户确认（y/n/逐个确认）后才进入下一步
7. 对确认的段落按类型执行更新：
   ```
   tech-stack         → 继承原表格风格，用最新依赖数据重建
   project-structure   → 继承原树形风格，用最新目录扫描重建
   interface-overview  → 继承原表格风格，用最新接口数据重建
   quick-start         → 只替换命令部分（代码块），保留说明文字
   config-reference    → 继承原表格风格，用最新配置数据重建
   ```
8. **段落边界规则**：修改范围 = 从匹配标题的下一行起，到下一个同级或更高级标题前止。**H4 等子标题也视为段落边界**，不会吞掉子标题
9. **非匹配段落零触碰**：未识别的标题段落完全不动
10. **修改后备份**：`→ ~/.readme-alive/backups/{project}/{ts}_after-fix.md`
11. 输出每个段落的 before/after 对比

### 风格继承规则

| 元素 | 检测方式 | 继承策略 |
|------|----------|----------|
| 标题 emoji | 正则匹配标题前缀 `## 🛠️ xxx` | 精确复用原 emoji |
| 标题语言 | 中文字符占比 | 中文 README 用中文列头，英文 README 用英文列头 |
| 表格列数 | 原表格的 `\|` 分隔符数量 | **保留原列数**。列数变化时输出警告询问用户处理方式，不静默合并或丢弃 |
| 表格对齐 | `:---` / `:---:` / `---:` | 精确复用 |
| 代码块语言标签 | ``` 后的标识符 | 精确复用 |
| 目录树前缀 | `├──` / `└──` / `│` 或缩进风格 | 精确复用 |

---

## 无 README 基线（Greenfield 模式）

当项目没有 README.md 时：

1. 跳过 Agent B（无需解析）
2. Agent A 正常扫描，输出正向枚举报告（不是"差异"报告，因为没有对比基准）
3. 报告末尾提示："项目尚无 README.md。是否需要基于模板生成一份草稿？"
4. 用户确认后，根据项目类型选择模板，生成精简 README 草稿：

   模板选择决策表：
   | 项目类型 | 模板文件 |
   |----------|----------|
   | `web-app` | `references/templates/web-app.md` |
   | `library` | `references/templates/library.md` |
   | `cli-tool` | `references/templates/cli-tool.md` |
   | `monorepo` | `references/templates/monorepo.md` |
   | `unknown` | `references/templates/web-app.md`（最通用兜底） |

   - 只包含核心章节：描述、安装、使用示例、技术栈、贡献指南、许可证
   - 技术栈等结构化数据使用 Agent A 的扫描结果填充
   - **不在 README 中留下任何工具标记**（生成的草稿是纯净 Markdown，用户拿到即用）
   - 在终端输出提示："README 草稿已生成。你可以直接编辑或提交。如需后续自动维护，可运行 /readme-alive --fix"

---

## 备份与回滚系统

### 备份目录（已迁出项目根目录）

```
~/.readme-alive/backups/<project-hash>/
├── manifest.json                      # 备份索引
└── 20260604T143000Z_before-fix.md     # 备份文件
```

- 备份存储在用户 home 目录下，不污染项目目录
- `<project-hash>` 是项目根目录路径的哈希，区分不同项目
- 首次使用时告知用户备份位置

### --backup / --undo / --diff-backup

```
/readme-alive --backup                # 手动快照
/readme-alive --backup "重构前"       # 带标签快照
/readme-alive --undo                  # 回滚到最近备份
/readme-alive --undo 3                # 回滚到编号 3
/readme-alive --undo --list           # 列出所有备份（含时间、操作、行数、标签）
/readme-alive --diff-backup           # 当前 vs 最近备份
```

### 回滚安全原则

- **写前必存**：`--fix` 执行前自动备份
- **回滚可逆**：`--undo` 前备份当前状态（可撤销的撤销）
- **操作透明**：每次恢复前展示 diff 预览
- **保留 20 个备份**：自动清理早期备份

**卸载清理**：删除 skill 后，备份数据仍保留在 `~/.readme-alive/backups/` 和 `~/.readme-alive/snapshots/`。如需彻底清理，运行 `rm -rf ~/.readme-alive/`。

---

## 审计维度

### 通用（所有项目）

| 维度 | 严重度 |
|------|--------|
| 依赖版本与构建文件是否一致 | 🔴 Critical |
| 对外接口（API/CLI/导出）与代码是否一致 | 🔴 Critical |
| 命令（安装/启动/测试）是否可执行 | 🔴 Critical |
| 内部链接是否可达 | 🔴 Critical |
| 新模块/目录是否在 README 中提及 | 🟡 Warning |
| 新依赖/配置是否在 README 中说明 | 🟡 Warning |
| README 长度是否与项目规模成比例 | 🔵 Info |
| 是否包含应迁移到 CHANGELOG 的内容 | 🔵 Info |
| 是否缺少关键章节（安装/使用/许可证） | 🔵 Info |

### 按项目类型

见 `references/audit-dimensions.md`。

---

## 非 Git 环境

- 默认增量模式依赖 `git diff`，无 Git 时自动降级为全量扫描
- `.gitignore` 不存在时使用内置默认排除列表
- 备份系统不依赖 Git，直接操作文件系统
- 审计报告标注 `[No Git]`，提示用户初始化 Git 仓库以获得更好的增量体验
- **伪增量优化**：非 Git 环境下首次全量扫描后，在 `~/.readme-alive/snapshots/<project-hash>/` 保存文件清单+哈希快照（`file-snapshot.json`）。后续审计对比快照中文件的哈希值变化，仅重新扫描变更文件。快照每次审计后更新。此机制为可选增强，快照损坏或丢失时自动降级为全量扫描。审计报告 metadata 中 `snapshotStatus` 字段记录快照状态（`used` / `degraded` / `none`）。若连续 3 次快照损坏/丢失导致降级为全量扫描，终端输出 Warning 建议检查 `~/.readme-alive/snapshots/` 目录权限。

---

## 不支持的语言

项目语言不在内置 5 种（Java/Node.js/Python/Go/Rust）中时：
- 跳过语言特定的深度扫描
- 仍执行通用审计（项目结构、README 章节、链接、长度比例）
- 报告中标注 `[Generic Audit]`
- 不影响 `--fix` 的段落识别和风格继承

---

## 安全规则

> **⚠️ 安全红线**
> 
> **违反以下任何一条安全规则将导致审计结果无效。**
> 
> Agent 加载 scanner 时应重申以下安全规则，确保各子 Agent 严格遵守。

- **敏感文件过滤**：不读取 `.env*`（仅读取 `.env.example`）、`*.key`、`credentials.*`、`*.pem`、`*.p12`、`secrets.*`、`*.token`、`*.secret`、`privatekey*`、`id_rsa*`、`id_ed25519*`、`id_ecdsa*`、`.npmrc`、`.pypirc`、`.docker/config.json`、`git-credentials`、`*.jks`、`*.keystore`、`*.truststore`、`*.pfx`、`*.pkcs12`、`terraform.tfvars`、`*.auto.tfvars`、`connectionStrings.*`、`appsettings.*.json`、`secret.*`、`private_key*`、`*_rsa`、`*_ed25519`、`*_ecdsa`、`*.kubeconfig`、`*.ovpn`、`.dockercfg`
- **敏感文件兜底规则**：如果文件名或路径暗示包含凭证/密钥/令牌，即使不在上述列表中，也应跳过并记录 WARNING
- **自定义排除规则**：支持项目根目录放置 `.readme-alive-ignore` 文件自定义排除规则（格式同 `.gitignore`）
- 遵守 `.gitignore` 排除规则（无 `.gitignore` 时使用内置默认排除列表）
- 单文件 >1MB 跳过
- 文件数 >5000 自动采样并标注 `[Sampled]`（策略见 `references/sampling-strategy.md`）
- 所有修改操作前自动备份，支持 `--undo` 恢复
- `--undo` 前也备份（可撤销的撤销）
- 保留最近 20 个备份，超出自动清理
- **不在用户 README 中留下任何工具标记或注释**（草稿模式的一次性标记除外）
- 不修改非目标段落的内容
- 不自动生成 CHANGELOG

## 输出格式

审计报告包含：
1. **执行摘要**：Tier 级别 + 选择原因简述（格式：`Tier 2 [auto→T2→B超时降级T1]`）、扫描文件数、Token 消耗、环境状态
2. **按严重度分组**：🔴 Critical → 🟡 Warning → 🔵 Info
3. **每项差异**：所处章节、具体问题、建议操作
4. **覆盖率统计**：代码模块/接口/配置 vs README 已覆盖
5. **可自动修复项**：`--fix` 可处理的段落
6. **比例化长度评估**：当前 README 行数 vs 项目规模合理范围