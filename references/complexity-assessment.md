# 复杂度评估算法

## 目的

在 Phase 0 快速评估项目复杂度（1-10 分），决定使用哪个 Agent Tier。

## 评估维度

| 维度 | 权重 | 计算方式 | 评分标准 |
|------|------|----------|----------|
| **文件数** | 35% | 源码文件总数（排除 node_modules/.git/target/vendor/build/dist/__pycache__ 等） | <20:1分, 20-50:2分, 50-100:3分, 100-300:4分, 300-500:5分, 500-1000:6分, 1000-2000:7分, 2000-5000:8分, 5000-10000:9分, >10000:10分 |
| **模块数** | 20% | 顶层包/模块/子项目数量 | 1:1分, 2-3:2分, 4-5:3分, 6-8:4分, 9-12:5分, 13-20:6分, 21-30:7分, 31-50:8分, 51-100:9分, >100:10分 |
| **语言数** | 20% | 检测到的编程语言种类 | 1:1分, 2:4分, 3:7分, 4+:10分 |
| **项目类型** | 15% | Monorepo/多包 vs 单体 | Monorepo:10分, 多包(workspaces):7分, 单体+前端:5分, 单体:1分 |
| **README 规模** | 10% | 当前 README.md 行数 | <50:1分, 50-100:2分, 100-200:3分, 200-400:5分, 400-800:7分, >800:10分 |

## 计算公式

```
raw_score = 文件数分 × 0.35 + 模块数分 × 0.20 + 语言数分 × 0.20 + 项目类型分 × 0.15 + README分 × 0.10
complexity = round(raw_score)
```

## Tier 映射

```
complexity 1-3  → Tier 0（单 Agent 串行）
complexity 4-6  → Tier 1（2 Agent 并行，默认）
complexity 7-10 → Tier 2（N Agent 扇出）
```

**边界缓冲**：raw_score 在 Tier 边界 ±0.5 范围内（即 3.0-3.9 或 6.0-6.9）时，结合以下辅助信号对 raw_score 进行量化调整：

| 辅助信号 | 触发条件 | 调整值 |
|----------|----------|--------|
| CI/CD 配置存在 | 检测到 `.github/workflows/`、`Jenkinsfile`、`.gitlab-ci.yml`、`azure-pipelines.yml` 等 | +0.3 |
| 近期活跃 | 近 30 天 ≥10 commits | +0.2 |
| 项目有 CI 徽章 | README 中包含 CI/CD 状态徽章（如 GitHub Actions badge、Travis CI badge 等） | +0.1 |

**叠加与上限**：多个信号可叠加，但累计调整上限为 **+0.5**。调整后若 raw_score 跨过 Tier 边界则采纳新 Tier，否则保持原 Tier。

辅助信号仅在边界区（3.0-3.9 或 6.0-6.9）内起作用，不改变非边界区的 Tier 判定。

### 扇出上限与采样策略

Tier 2 的并行 Agent 数量上限为 **8 个**。当文件数极大导致采样策略需要进一步降低采样率时，按以下优先级处理：

1. 首先尝试在 ≤8 Agent 的扇出内完成审计（调整 Agent 分工粒度和采样率）。
2. 若已达 8 Agent 上限且仍需降低采样率以满足 token 预算 → 进一步降低采样率（**不低于采样率下限**，参见 `sampling-strategy.md`）。
3. 若采样率已触达下限仍无法满足预算 → 输出 `[CoverageLimited]` 警告，降级至 Tier 1 兜底策略。

## 文件计数细则

### 计入的文件类型
- Java: .java
- Python: .py
- JavaScript/TypeScript: .js, .ts, .jsx, .tsx, .mjs, .cjs
- Go: .go
- Rust: .rs
- 配置: .yml, .yaml, .json, .toml, .xml, .properties, .env.example
- 文档: .md, .rst
- 构建: Dockerfile, Makefile, CMakeLists.txt, build.gradle
- Shell: .sh, .bash, .zsh

### 排除的目录
node_modules, .git, target, build, dist, vendor, __pycache__, .venv, venv, .idea, .vscode, .claude, coverage, .next, .nuxt, .output, out

## 语言检测

按置信度检测以下特征文件（顺序反映检测可靠性，非排他优先级）：
1. pom.xml + src/main/java → Java (Spring Boot 如果含 spring-boot-starter-parent) — 置信度：极高
2. build.gradle + src/main/java → Java (Gradle) — 置信度：极高
3. package.json → JavaScript/TypeScript (Node.js) — 置信度：高
4. go.mod → Go — 置信度：极高
5. Cargo.toml → Rust — 置信度：极高
6. pyproject.toml / setup.py / requirements.txt → Python — 置信度：高

**置信度的使用场景**：
- 置信度仅用于**确定主语言以选择默认 scanner**（置信度最高的语言优先作为主语言）。
- **所有检测到的语言都会被加载对应 scanner**，不因置信度低而跳过。
- 主语言用于 Tier 2 扇出策略中的第一个 Agent 的专注方向。
- 多种语言检测到时，语言数 +1（每种语言独立计数），不影响评分。

## 模块计数

### Java
- 统计 src/main/java/ 下的顶层包目录数（如 com/example/userservice 算 1 个模块）
- 或者统计 Maven module 数（多模块项目）

### Node.js
- 统计 package.json 中 workspaces 数量
- 无 workspaces 则统计 src/ 下的顶层目录数

### Python
- 统计 src/ 或项目根目录下的顶层 Python 包数（含 __init__.py 的目录）
- 或统计 pyproject.toml 中的 packages 数

### Go
- 统计 go.mod 所在目录下的顶层包目录数（排除 internal、vendor）

### Rust
- 统计 Cargo.toml workspace members 数量
- 单 crate 统计 src/ 下的模块文件数

### Monorepo 检测
- 存在多个 package.json（Node.js workspaces）
- 存在多个 Cargo.toml（Rust workspace）
- 存在多个 go.mod（Go 多模块）
- 存在多个 pom.xml（Maven 多模块）
- 根目录有 lerna.json / nx.json / turbo.json

## 手动覆盖

用户可通过 `--tier N` 强制指定 Tier，跳过自动评估：
- `--tier 0`：适合"我只改了一行代码"的快速检查
- `--tier 1`：默认级别
- `--tier 2`：适合"我需要非常彻底的审计"

## CLI 实现对照

以下映射关系用于追溯规范→代码实现：

| 规范维度 | CLI 函数 | 变量名 | 说明 |
|----------|----------|--------|------|
| 文件数分 | `do_complexity()` | `fscore` | 源码文件总数评分（1-10） |
| 模块数分 | `do_complexity()` | `mscore` | 顶层包/模块/子项目数评分（1-10） |
| 语言数分 | `do_complexity()` | `lscore` | 检测到的编程语言种类评分（1-10） |
| 项目类型分 | `do_complexity()` | `proj_score` | Monorepo/多包/单体评分（1-10） |
| README 规模分 | `do_complexity()` | `rscore` | README.md 行数评分（1-10） |
| 原始加权分 | `do_complexity()` | `raw_score` | 五维加权求和结果 |
| 最终复杂度 | `do_complexity()` | `complexity` | `round(raw_score)`，1-10 |
| 边界缓冲调整 | `do_complexity()` | `boundary_adjust` | 辅助信号累计调整值（上限 +0.5） |
| 最终 Tier | `do_complexity()` | `tier` | 0/1/2，经边界缓冲修正后的结果 |

### 边界缓冲变量

| 信号 | CLI 变量 | 类型 |
|------|----------|------|
| CI/CD 配置存在 | `has_ci_config` | `bool` |
| 近期活跃（>=10 commits/30d） | `is_recently_active` | `bool` |
| 项目有 CI 徽章 | `has_ci_badge` | `bool` |
| 边界区内标志 | `in_boundary_zone` | `bool` |

### Token 预算注意事项

在 Tier 预估阶段需预留固定 instruction overhead（约 **5-7K tokens**），该开销来源于：
- 系统提示词（system prompt）
- 工具定义（tool definitions）
- 审计指令框架（audit instruction scaffolding）

实际审计可用 token 预算 = 模型 context window - 5-7K overhead。在 Tier 2 扇出分配时须将 overhead 考虑在内，避免单个 Agent 因实际可用 token 不足而截断输出。