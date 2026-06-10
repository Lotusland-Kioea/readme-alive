# 大项目采样策略

## 触发条件

当项目源码文件数 >5000 时触发采样模式，避免全量扫描导致 Token 溢出或超时。

## 采样方法：分层优先级抽样

### 第一层：强制纳入（100% 覆盖）

以下文件**永不跳过**，无论文件数多少：

| 类别 | 文件示例 | 原因 |
|------|---------|------|
| 构建配置 | `pom.xml`, `build.gradle*`, `package.json`, `go.mod`, `Cargo.toml`, `pyproject.toml`, `Makefile`, `Dockerfile` | 包含依赖版本、构建命令等核心审计数据 |
| 环境配置 | `.env.example`, `application.yml`, `config.yaml`, `config/default.toml` | 配置项审计的关键来源 |
| 项目入口 | `main.go`, `main.rs`, `app.ts`, `Application.java`, `main.py`, `index.ts` | 确定项目类型和启动命令 |
| 路由/端点定义 | `routes/`, `router/`, `urls.py`, `controller/` 目录下的文件 | API 端点审计的关键来源 |
| README 引用的文件 | README 中通过路径引用的文件 | README 一致性审计的直接参考 |

### 第二层：目录分层抽样

对非强制的源码文件，按目录层级抽样：

1. **按顶层目录分组**：将项目按 `src/`、`internal/`、`pkg/`、`packages/` 等顶层目录分组
2. **每组抽样率**：
   - 该组文件数 <100：100%（全量）
   - 该组文件数 100-500：50%
   - 该组文件数 >500：至少 20%，不少于 200 个文件
3. **抽样方式**：按文件修改时间倒序排列，取最近的 N 个（最近修改的文件更可能反映当前状态）

### 第三层：扩展名覆盖保证

确保每种源码文件类型至少有 10 个文件纳入扫描：

- 该扩展名文件数 <10：全量
- 该扩展名文件数 ≥10：至少随机选取 10 个

## Tier 2 协调采样

Tier 2 扇出时，采样由主 Agent 协调：

1. 主 Agent 先执行分层抽样，确定各子 Agent 的扫描范围
2. 每个子 Agent 收到的是**已采样的文件列表**，而非原始完整目录
3. 各子 Agent 的扫描结果汇总时不做二次抽样
4. 审计报告 `metadata` 中标注 `"sampled": true` 和 `"samplingRate": "20%"` 等信息

## 采样率下限

| 文件总数 | 最低采样率 | 最低绝对采样数 |
|---------|-----------|--------------|
| 5,000-10,000 | 30% | 1,500 |
| 10,000-20,000 | 20% | 2,000 |
| 20,000-50,000 | 15% | 3,000 |
| >50,000 | 10% | 5,000 |

## 审计报告标注

采样模式下，审计报告 `metadata` 中新增：

```json
{
  "sampled": true,
  "samplingRate": "20%",
  "totalFiles": 8500,
  "sampledFiles": 1700,
  "mandatoryFilesIncluded": 45,
  "samplingMethod": "stratified-priority",
  "coverageBasis": "sampled"
}
```

### 覆盖率双重输出

采样模式下需同时输出两个覆盖维度的覆盖率指标：

| 覆盖维度 | 字段名 | 标记 | 计算方式 |
|----------|--------|------|----------|
| 采样文件实际覆盖率 | `sampledCoverage` | `[Sampled]` | 在已采样文件的范围内计算覆盖率百分比 |
| 外推全量估算覆盖率 | `estimatedFullCoverage` | `[Estimated]` | `sampledCoverage × samplingRate`，外推至全量文件的估算值 |

报告中所有基于文件计数的结论（如模块覆盖率）需标注 `[Sampled]` 前缀。涉及全量外推的结论需标注 `[Estimated]` 前缀以区分确定性。

`coverageBasis` 字段说明：
- `"full"` — 未启用采样，覆盖率基于全量文件计算
- `"sampled"` — 启用采样，覆盖率优先使用 `sampledCoverage`；`estimatedFullCoverage` 作为补充参考

## 降级替代

当采样后文件数仍超过单 Agent 处理能力时，按以下优先级处理：

1. **升级到 Tier 2**：将采样文件分配至多个 Agent 并行处理
2. **已达 Tier 2 扇出上限**（8 Agent）→ 进一步降低采样率（**不低于采样率下限**，见上文表格）
3. **采样率已触达下限** → 输出 `[CoverageLimited]` 警告，标注"当前采样率已达下限但仍超出单 Agent 处理能力，建议用户拆分项目或使用 `--include-only` 聚焦核心路径"

| 决策分支 | 条件 | 动作 |
|----------|------|------|
| 采样后文件量可接受 | 单 Agent 可处理 | 保持当前 Tier |
| Tier 2 未达上限 | 有可用 Agent 槽位 | 升级到 Tier 2，维持采样率 |
| Tier 2 已达 8 Agent 上限 | 无多余槽位 | 降低采样率（不低于下限） |
| 采样率已触达下限 | 无法再降 | 输出 `[CoverageLimited]` 警告 |

> **设计原则**：采样审计不如全量审计准确，但远比"跳过检查"有价值。标注 `[Sampled]`/`[Estimated]`/`[CoverageLimited]` 保证透明度。
