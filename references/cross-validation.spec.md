# 交叉验证规范 (Cross-Validation Specification)

## 概述

定义 Phase 2 中 Agent A（代码扫描）与 Agent B（README 解析）输出结果的交叉验证算法。

## 1. 接口签名规范化

### 1.1 HTTP 端点签名规范化规则
- 路径参数统一为 `:param` 格式（`{id}`、`<id>` → `:id`）
- HTTP 方法统一大写
- 去除首尾空格和多余 `/`
- 查询参数按字母序排列（如果可提取）
- 示例：`GET /api/users/:id`

### 1.2 CLI 命令签名规范化规则
- 子命令按顺序拼接（`app serve start`）
- 选项/标志按字母序排列（`--port <int>`、`--verbose`）
- 示例：`app serve --port <int> --workers <int>`

### 1.3 库导出符号规范化规则
- 函数签名：`packageName.functionName(param1: Type, param2: Type) -> ReturnType`
- 类签名：`packageName.ClassName`
- 示例：`mypackage.UserService.createUser(user: CreateUserDTO) -> User`

## 2. 依赖版本对比规则

### 2.1 版本号规范化
- 剥离前缀字符（如 `v`、`^`、`~`、`>=`、`<`）
- 保留核心版本号三段式（major.minor.patch）
- 处理特殊版本：`latest`、`nightly`、`SNAPSHOT`、`RELEASE`

### 2.2 严重度判定矩阵
| README 版本 | 代码实际版本 | 判定 |
|------------|------------|------|
| 精确匹配 | 同 | ✅ 无问题 |
| 精确数字 | 不同数字 | 🔴 Critical：版本不匹配 |
| 范围表达式（>=1.0） | 在范围内 | ✅ 无问题 |
| 范围表达式（>=1.0） | 不在范围内 | 🔴 Critical |
| 未标注版本 | — | 🟡 Warning：建议标注版本 |
| 未在 README 提及 | — | 🟡 Warning：依赖未覆盖 |

## 3. 模糊匹配算法

### 3.1 低置信度匹配（Levenshtein 距离）
当精确字符串匹配失败时，对签名进行 Levenshtein 距离计算：
- 距离 ≤ 2 且长度 ≥ 10 字符 → 高概率匹配，标记 `[Fuzzy:High]`
- 距离 ≤ 5 且长度 ≥ 10 字符 → 中概率匹配，标记 `[Fuzzy:Medium]`，需人工确认
- 距离 > 5 → 不匹配

### 3.2 路径参数模式匹配
- `:id`、`{id}`、`<id>`、`<int:id>`、`<str:id>` → 统一规范化后比较
- 优先做精确 canonicalForm 比较，如有差异再进行模糊匹配

### 3.3 接口匹配流程（伪代码）
```
for each code_interface in AgentA.interfaces:
    canonical_a = normalize(code_interface.signature)
    best_match = null
    for each readme_interface in AgentB.declaredInterfaces:
        canonical_b = normalize(readme_interface.signature)
        if canonical_a == canonical_b:
            best_match = { match: 'exact', confidence: 1.0 }
            break
        distance = levenshtein(canonical_a, canonical_b)
        if distance <= threshold:
            best_match = update_best(distance)
    if best_match is null:
        findings.add(Warning: "接口未在 README 中记录", code_interface)
    elif best_match.match == 'fuzzy':
        findings.add(Info: "接口描述可能过时", best_match)
```

## 4. 配置项对比规则

### 4.1 配置键规范化
- 环境变量：统一为大写 + 下划线（`DATABASE_URL`）
- YAML properties：保留点号层级（`server.port`）
- 注解/代码提取：按来源格式保持

### 4.2 对比规则
- Agent A 提取的配置项 vs Agent B README 中声明的配置项
- 按规范化后的 key 做精确匹配
- Agent A 有而 Agent B 无 → 🟡 Warning：配置项未文档化
- Agent B 有而 Agent A 无 → 🔴 Critical：README 引用了不存在的配置项（需排除可选配置）

## 5. 命令可执行性验证

### 5.1 命令提取与验证
- Agent A 从构建文件/Makefile/CLI 定义提取有效的安装/启动/测试命令
- Agent B 从 README 代码块提取命令文本
- 对比规则：命令的"骨架"匹配（忽略选项的具体参数值，匹配命令名+子命令名）
- 示例：`npm install` 与 `npm install --save-dev` → 骨架匹配（`npm install`）

### 5.2 判定规则
- README 命令不存在于项目中 → 🔴 Critical
- README 命令骨架匹配但参数/选项不同 → 🟡 Warning
- README 命令完全匹配 → ✅ 无问题

## 6. 链接有效性验证

### 6.1 内部链接检查
- 解析 README 中的相对路径链接（排除 http/https/mailto 等外部协议）
- 检查链接目标文件/目录是否在仓库中存在
- 检查锚点链接（`#section-name`）是否对应 README 中的实际标题

### 6.2 判定规则
- 链接目标不存在 → 🔴 Critical
- 链接目标是目录但不可达 → 🔴 Critical
- 锚点对应的标题不存在 → 🟡 Warning

## 7. 综合交叉验证流程（Phase 2）

### 7.1 输入
- Agent A 输出（`agent-a-output.schema.json` 格式）
- Agent B 输出（`agent-b-output.schema.json` 格式，如 README 不存在则为 null）

### 7.2 执行步骤
1. 依赖版本交叉验证（§2）
2. 接口签名交叉验证（§3）
3. 配置项交叉验证（§4）
4. 命令可执行性验证（§5）
5. 链接有效性验证（§6）
6. 结构/模块覆盖验证（通用维度）
7. 生成 audit-report（`audit-report.schema.json` 格式）

### 7.3 输出
- 差异报告（audit-report.schema.json 格式）
- 如 Agent B 输出为 null（Greenfield 模式）：正向枚举报告（reportType=greenfield-enum）
