# Agent 升级策略

## 设计理念

借鉴 Java 锁升级机制（偏向锁 → 轻量级锁 → 重量级锁），根据项目复杂度自动选择 Agent 策略。

## 自动升级路径

```
Phase 0 评估复杂度
  → complexity 1-3  → Tier 0（单 Agent 串行）
  → complexity 4-6  → Tier 1（2 Agent 并行，默认）
  → complexity 7-10 → Tier 2（N Agent 扇出）
```

## 运行时自动修正

Phase 0 的静态评估基于文件数和模块数等粗略指标，可能在以下情况误判：

### 升级场景（Tier 不足 → 动态升级）

| 场景 | 静态评估 | 实际发现 | 修正动作 | 已扫描数据处置 |
|------|---------|---------|---------|---------------|
| 项目用 `.gitignore` 排除了大量生成文件 | Tier 1 (复杂度 4) | Agent A 扫描发现实际源码 600+ 文件 | 追加 Agent A，升级到 Tier 2 | 已有 Agent A 扫描结果复用（标注 `[partial]`），仅对新发现的路径启动新 Agent |
| Phase 0 未检测到 Monorepo（非标准结构） | Tier 1 (复杂度 5) | Agent A 发现 8 个独立子模块 | 按子模块扇出，升级到 Tier 2 | 已覆盖的模块结果复用（标注 `[partial]`），仅对未被覆盖的子模块启动新 Agent |
| 检测为单模块但实际包含巨型文件 | Tier 0 (复杂度 3) | 单文件 5000+ 行含大量 API 端点 | 升级到 Tier 1 | 原 Agent A 结果保留，追加 Agent A 并行处理拆分后的分段 |

**升级触发条件**（满足任一）：
- 实际扫描文件数 > Phase 0 估计值的 2 倍
- 未检测为 Monorepo 但发现 ≥ 3 个独立模块（各有独立构建文件）
- Phase 0 未检测到的额外语言（如项目内含 `scripts/` 用另一种语言）
- Agent A 返回超时/截断 → 需要拆分为多个 Agent A

### 冲突裁决

当升级条件和降级条件同时满足时（如 Agent A 发现 Monorepo 结构触发升级，同时大部分子模块文件数 <30 触发降级），采用**升级优先**原则：

- Monorepo 发现是结构性信息，比文件数估计误差更可信
- 冲突时优先升级，确保不因保守估计遗漏审计覆盖
- `tierReason` 格式示例：`conflict(upgrade:monorepo downgrade:<30files)→upgrade→Tier2`

### 降级场景（Tier 过高 → 合并降级）

| 场景 | 静态评估 | 实际发现 | 修正动作 |
|------|---------|---------|---------|
| Phase 0 高估模块数（空目录被计数） | Tier 2 (复杂度 7) | 扇出后每个子 Agent 只扫到 <30 文件 | 合并 Agent，降级到 Tier 1 |
| 检测为多语言但次要语言仅含 1-2 个脚本 | Tier 2 (复杂度 8) | 次要语言不是核心代码 | 合并到主语言 Agent，降级到 Tier 1 |

**降级触发条件**（满足任一）：
- 扇出后 ≥ 50% 的子 Agent 扫描文件数 <30
- 检测到的"多语言"中，次要语言文件数 <5 且无独立构建文件

**降级安全防护**（前置检查）：若降级涉及合并 Agent，必须先验证合并后总文件数 ≤ 目标 Tier 的安全上限：
- 合并后总文件数 > 500（Tier 1 安全上限）→ **拒绝降级**，保持当前 Tier
- 若合并后总文件数 ≤ 500 → 允许降级
- 此检查确保降级不会导致单个 Agent 超载

### 修正记录

所有修正写入审计报告：

```json
{
  "metadata": {
    "tier": 2,
    "tierReason": "auto→Tier1→runtime-upgrade→Tier2: 实际源码 623 文件，Phase 0 低估",
    "initialComplexity": 5,
    "adjustedComplexity": 8
  }
}
```

## 降级场景（非运行时）

### Agent B 超时/失败降级

Agent B（README 解析）在 Tier 2 下始终为 1 个，当 README 过大（800+ 行）或 Agent B 超时时：

1. **超时检测**：Agent B 超过 30 秒未返回 → 触发降级
2. **降级动作**：
   - Agent B 跳过，审计退化为代码侧单向枚举模式
   - 交叉验证不可用，报告中只输出正向枚举（"代码实际有什么"）
   - 段落检测和 `--fix` 仍可用（基于最后一次成功解析的 README 缓存）
3. **标注**：审计报告 `summary.fallbackNote` 中标注 `[Agent B timeout: README too large (850 lines), cross-validation skipped]`
4. **强制步骤**：降级时必须在 `fallbackNote` 中追加可操作建议文本，例如：
   - `建议拆分 README 为多个文件后重试`
   - `建议将长表格/附录移至单独文档，缩减 README 主体`
   - `建议使用 --tier 0 跳过 README 解析直接审计代码`

#### Agent B 超时检测实现规格

##### 超时阈值

默认 **30 秒**，可通过环境变量 `README_ALIVE_AGENT_B_TIMEOUT` 配置（单位：秒，最小值 10，最大值 120）。

##### Heartbeat 机制

Agent B 每输出一个 section（H2 章节内容）后更新心跳时间戳。主 Agent 以轮询方式检查心跳：

```
heartbeat = {
  last_update: timestamp,    // 最后心跳时间
  sections_completed: int,   // 已完成 H2 数量
  current_section: string    // 当前处理的 H2 标题
}
```

##### 超时检测与 Cancel

主 Agent 采用 **fire-and-forget 并行策略**：

```
// 伪代码
fn run_agent_b_with_timeout(readme_content, timeout_secs):
    agent_b_handle = launch_agent_b(readme_content)  // 异步启动，不阻塞
    start_time = now()
    
    loop every 2 seconds:  // 轮询间隔
        if agent_b_handle.is_complete():
            return agent_b_handle.result()
        
        elapsed = now() - start_time
        last_heartbeat = agent_b_handle.heartbeat.last_update
        
        if elapsed > timeout_secs:
            agent_b_handle.cancel()  // 发送 cancel 信号
            return TimeoutResult(
                reason = "Agent B 超时",
                elapsed = elapsed,
                sections_completed = agent_b_handle.heartbeat.sections_completed,
                fallback_note = generate_fallback_note(...)
            )
        
        // 心跳丢失检测（连续 10 秒无心跳 → 视为卡死）
        if now() - last_heartbeat > 10:
            agent_b_handle.cancel()
            return TimeoutResult(reason = "Agent B 心跳丢失")
```

##### Cancel 信号

Agent B 收到 cancel 信号后：
- 立即停止当前 section 处理
- 保留已完成 section 的输出（部分结果可用）
- 在输出末尾标记 `[Agent B CANCELLED: sections 3/12 completed]`

当 README 可被分块处理时（有明确的 H2 标题边界），可尝试以下优化：
- 按 H2 章节拆分 README 为多个片段
- 每个片段由独立的子 Agent 解析
- 结果在主 Agent 合并

此优化为可选增强，非必须降级路径。

### 自动降级（平台限制）

当 Tier 1 或 Tier 2 的 Agent 创建失败时（平台不支持多 Agent、并发限制等）：
1. 自动降级到 Tier 0
2. 在审计报告中标注 `[Tier 0 Fallback: <原因>]`
3. 审计内容不受影响（只是少了并行加速）

### 手动降级

用户显式指定 `--tier 0`：
- "我只改了一行代码，不想烧 token" → 快速审计
- CI 环境限制 → 单 Agent 更可控
- 微型项目（<20 文件）→ 不需要并行

### 最低报告质量门禁

当以下两个降级条件同时激活时，触发最低报告质量门禁：

| 降级条件 | 触发条件 |
|----------|----------|
| `[Sampled]` | 文件采样率 < 100%（见 `sampling-strategy.md`） |
| `[Agent B timeout]` | Agent B 超时导致交叉验证不可用 |

**门禁规则**：当 `[Sampled]` + `[Agent B timeout]` 同时激活且采样率 < **30%** 时：

1. **中断审计**：当前审计流程终止，不生成最终报告
2. **引导修复**：向用户输出明确的前置条件修复指引：
   - `建议拆分 README 为多个文件，将总行数控制在 400 行以下`
   - `建议使用 --tier 1 降低并行度以提高单 Agent 可用 token 预算`
   - `建议使用 .readme-alive-ignore 排除非核心目录以提升采样率至 30% 以上`
   - `建议使用 --include-only 聚焦核心路径`
3. **输出格式**：审计报告仅包含 `summary.fallbackNote`，标记 `[QualityGate:FAILED sampling_rate=X% agent_b=timeout]`
4. **覆盖**：用户可通过 `--no-quality-gate` 跳过此门禁，强制生成低质量报告

## Tier 2 扇出策略

### 拆分优先级

1. **按业务相关性聚合** → 将业务相关的子包/模块聚合到同一 Agent（如"用户服务模块"包含 3 个相关子模块），优先保证审计语义完整性
2. **多语言** → 每种语言一个 Agent（扫描规则差异大）
3. **前后端分离** → 前端 + 后端各一个（目录结构独立）
4. **超多模块** → 按顶层目录分组，每组 50-200 文件为 1 Agent
5. **Monorepo** → 当 Monorepo 子包之间业务无关时，按子包独立分配 Agent；否则按业务相关性聚合

### 扇出上限

- 扇出 Agent 数上限 = min(项目模块数, 8)
- 防止过度扇出导致调度开销超过扫描本身
- 剩余模块合并到最后一个 Agent

### 扇出示例

**场景：Spring Boot 大型项目（15 个 Maven 模块 + Vue 前端）**
```
Agent A1: 用户服务模块 (3 子模块)
Agent A2: 订单服务模块 (3 子模块)
Agent A3: 支付服务模块 (3 子模块)
Agent A4: 公共模块 + 配置 (3 子模块)
Agent A5: 前端 (Vue 3, 1 模块)
Agent B:  README 解析
```
→ 共 6 Agent（5 代码扫描 + 1 README 解析）

**场景：Rust workspace（8 crates）**
```
Agent A1: crate-1, crate-2, crate-3
Agent A2: crate-4, crate-5, crate-6
Agent A3: crate-7, crate-8
Agent B:  README 解析
```
→ 共 4 Agent（3 代码扫描 + 1 README 解析）

**场景：Python Monorepo（12 个独立包）**
```
Agent A1: package-1, package-2, package-3
Agent A2: package-4, package-5, package-6
Agent A3: package-7, package-8, package-9
Agent A4: package-10, package-11, package-12
Agent B:  README 解析
```
→ 共 5 Agent（4 代码扫描 + 1 README 解析），12 子包封顶 8，实际用 4 个

## 性能考量

| Tier | Agent 数 | 适用项目 | 预计 Token | 预计耗时 |
|------|----------|----------|-----------|----------|
| Tier 0 | 1 | 微型/小型 | 5K-15K | 5-15s |
| Tier 1 | 2 | 中型 | 15K-40K | 10-25s |
| Tier 2 | 3-8 | 大型/Monorepo | 40K-150K | 20-60s |

注：默认增量模式（git diff HEAD~10）可减少 60-80% 的文件扫描量。

## 结果去重策略（Tier 2 专用）

当多个 Agent A 扫描不同模块时，可能出现重复发现（如同一依赖被多个模块引用）：

### 去重规则

1. **依赖去重**：按 `groupId:artifactId`（Maven）、`package-name`（npm）、`crate-name`（Cargo）去重，保留第一个发现的版本
2. **API 去重**：按 `方法 + 完整路径` 去重，完全相同的端点只保留一个
3. **配置项去重**：按 `配置 key` 去重
4. **模块去重**：不适用——各 Agent 扫不同模块，结果应合并而非去重

### 冲突处理

如果两个 Agent 报告了同一依赖的不同版本：
- 取较高版本（保守策略：README 应该反映最新状态）
- 在报告中标注 `[版本冲突: A1报告 v1.2, A2报告 v1.3, 采用 v1.3]`