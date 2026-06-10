# Changelog

## [1.0.0] — 2026-06-10

### 首个正式版

基于两轮企业级 code review 的全面修复发布。

### 架构设计
- Phase 0→1→2 三级流水线：环境检测 → 弹性审计 → 综合报告
- Tier 0/1/2 弹性 Agent 伸缩（借鉴 Java 锁升级机制）
- 复杂度自适应：文件数 × 模块数 × 语言数 × 项目类型 × README 规模加权评分
- 运行时自动修正：升级/降级触发 + 冲突裁决 + 降级安全防护

### 安全与稳定性
- 敏感文件过滤 35+ 模式（含 OWASP/GitHub 最佳实践）
- 备份原子写入 + chmod 600/700 权限控制
- 回滚可逆（--undo 前自动备份）
- Manifest 双层设计（JSON + 纯文本兜底）+ 输入校验防 JSON 注入
- LLM 安全指令强化为独立安全红线段落

### CLI 脚本（706 行）
- 基础检查：links / sections / files / structure / all
- 复杂度评估：5 语言模块计数 + 加权评分 + 边界缓冲
- 备份回滚：双层 manifest + 原子写入 + diff 预览
- JSON 输出：check/complexity 模式支持 --format json
- --tier 手动覆盖 + --force 强制模式
- 跨平台兼容：macOS/Linux（sha256sum/shasum 回退、mktemp 安全降级、ggrep 检测）

### 五语言深度扫描器，统一结构契约（6 MUST 章节）
- **Java/Spring Boot** — Maven 两阶段版本解析 + Gradle 全配置 + Gateway/BOM/WebSocket/gRPC
- **Node.js/TypeScript** — Express/Koa/Fastify/Hono/NestJS 跨文件追踪 + Next.js App Router + Vue/React Router
- **Python** — FastAPI/Django/Flask + pydantic-settings + DRF ViewSet + CLI 入口点（click/typer/argparse）
- **Go** — Gin/Echo/Fiber/Chi/Gorilla Mux + Cobra 嵌套子命令 + go.work workspace
- **Rust** — Actix/Axum/Rocket/Warp/Poem + Clap 双风格 + Cargo workspace

### Schema 与数据契约
- Agent A/B 输出 JSON Schema（draft 2020-12）
- canonicalForm 接口签名规范化（支持精确交叉验证）
- audit-report.schema.json（28 维度 enum + reportType + readmeStatus）
- 新增 cross-validation.spec.md（签名规范化/模糊匹配/版本对比/Phase 2 流程伪代码）

### 段落检测与风格继承
- 基于 H1-H3 标题的自然段落边界识别（5 种段落类型，100+ 关键词）
- 零痕迹设计（不插入 HTML 注释或标记）
- 风格嗅探：emoji/表格列数/对齐/代码块标签/目录树前缀/链接风格/列表前缀/Badge
- .readme-alive-keywords.json 自定义关键词扩展

### Greenfield 模式
- 4 套项目类型模板（web-app/library/cli-tool/monorepo）
- projectType→模板决策树 + unknown 兜底
- 模板标题关键词与段落检测系统对齐

### CI/CD
- GitHub Actions PR 检查 + 周检（--ci 模式）
- 周检 issue 去重 + skip 标记检测
- 报告敏感路径脱敏

### 兜底与降级
- 不支持语言 → Generic Audit（结构/章节/链接/长度）
- 非 Git 环境 → 伪增量快照 + snapshotStatus 追踪
- Agent B 超时 → heartbeat 检测 + 可操作建议 + 质量门禁
- 大项目采样 → 分层优先级抽样 + 双维度覆盖率

---

## [0.3.0-rc] — 2026-06-04

### 第一轮审查后修复
- 11 位专家并行审查，发现 45 Critical + 86 Warning
- 三轮修复（P0→P1→P2）全部清零
- 5 scanner 全面增强
- Phase C P2 改进：复杂度权重微调、Tier 边界缓冲区、大项目分层抽样、Agent B 超时降级、非中英文自定义关键词、非 Git 文件快照、Greenfield 补充

---

## [0.2.0] — 2026-06 (早期)

- Tier 2 N Agent 扇出 + Python/Go/Rust scanner
- Monorepo 检测与子项目审计
- Agent A/B 输出 Schema 定义

---

## [0.1.0] — 2026-06 (早期)

- 核心架构：Phase 0→1→2 + Tier 0/1 弹性伸缩
- Java/Spring Boot scanner + Node.js scanner
- 复杂度评估引擎 + references/readme-spec.md
- 审计报告生成
