#!/usr/bin/env bash
# readme-alive CLI v1.0.0 — README 质量守护工具（精简版）
# 用法: ./readme-alive.sh [--ci | --fix | --undo | --backup | --diff-backup | --check <dim> | --complexity]
# 完整 AI 功能（语义审计/智能修复）需在 Claude Code 中通过 /readme-alive 使用

set -euo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 配置 ---
README_PATH="${README_PATH:-README.md}"
BACKUP_BASE="${HOME}/.readme-alive/backups"
# [W5] 基于 git 项目根计算哈希，避免子目录运行导致备份分散
if command -v git &>/dev/null && git rev-parse --show-toplevel &>/dev/null; then
  PROJECT_HASH=$(echo "$(git rev-parse --show-toplevel)" | sha256sum 2>/dev/null | cut -c1-12)
elif echo "${PWD}" | sha256sum &>/dev/null 2>&1; then
  PROJECT_HASH=$(echo "${PWD}" | sha256sum 2>/dev/null | cut -c1-12)
fi
[[ -z "$PROJECT_HASH" ]] && PROJECT_HASH=$(echo "${PWD}" | shasum -a 256 2>/dev/null | cut -d' ' -f1 | cut -c1-12)
[[ -z "$PROJECT_HASH" ]] && PROJECT_HASH="unknown"
BACKUP_DIR="${BACKUP_BASE}/${PROJECT_HASH}"
MANIFEST_FILE="${BACKUP_DIR}/manifest.json"
MANIFEST_TXT="${BACKUP_DIR}/manifest.txt"
MAX_BACKUPS=20
FORMAT="text"
TIER_OVERRIDE=""  # [W1] --tier 手动指定复杂度等级（0/1/2），跳过自动评估
CI_MODE=false
FORCE_MODE=false  # [C3] --force 跳过非关键安全检查
DRY_RUN=false
VERBOSE=false
JSON_FINDINGS=""
JSON_FINDINGS_COUNT=0
JSON_WARNING_COUNT=0
JSON_INFO_COUNT=0

# --- JSON 输出工具 ---
json_escape() {
  # [I4] 转义 JSON 字符串中的特殊字符（含 C0 控制字符全集）
  local s="${1//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\f'/\\f}"
  s="${s//$'\b'/\\b}"
  # 其余 C0 控制字符（U+0000-U+001F 中未明确转义的）用 \uXXXX
  s=$(echo "$s" | LC_ALL=C sed -e 's/[\x00-\x08\x0B\x0E-\x1F]//g')
  echo "$s"
}

json_add_finding() {
  # 添加一条审计发现（仅在 FORMAT=json 时生效）
  local severity="$1" dimension="$2" title="$3" detail="${4:-}"
  local entry="{\"severity\":\"$severity\",\"dimension\":\"$dimension\",\"title\":\"$(json_escape "$title")\",\"detail\":\"$(json_escape "$detail")\"}"
  if [[ -z "$JSON_FINDINGS" ]]; then
    JSON_FINDINGS="$entry"
  else
    JSON_FINDINGS="$JSON_FINDINGS,$entry"
  fi
  ((JSON_FINDINGS_COUNT++))
}

json_output_check() {
  # 输出 check 模式的 JSON 报告
  local critical="$1"
  local ts=$(timestamp)
  local readme_exists="true"
  [[ ! -f "$README_PATH" ]] && readme_exists="false"
  cat <<JSONEOF
{
  "version": "$VERSION",
  "timestamp": "$ts",
  "mode": "check",
  "readme": "$README_PATH",
  "readmeExists": $readme_exists,
  "findings": [$JSON_FINDINGS],
  "summary": {
    "critical": $critical,
    "warning": $JSON_WARNING_COUNT,
    "info": $JSON_INFO_COUNT
  }
}
JSONEOF
}

json_output_complexity() {
  local ts=$(timestamp)
  cat <<JSONEOF
{
  "version": "$VERSION",
  "timestamp": "$ts",
  "mode": "complexity",
  "fileCount": $file_count,
  "fileScore": $fscore,
  "moduleCount": $module_count,
  "moduleScore": $mscore,
  "languageCount": $lang_count,
  "languageScore": $lscore,
  "projectType": "$proj_type",
  "projectTypeScore": $proj_score,
  "readmeLines": $readme_lines,
  "readmeScore": $rscore,
  "complexityScore": $complexity,
  "recommendedTier": $tier,
  "tierLabel": "$tier_label"
}
JSONEOF
}

# --- 颜色 ---
if [[ -t 1 ]]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

# --- 工具函数 ---
timestamp() { date -u +"%Y%m%dT%H%M%SZ" 2>/dev/null || date +"%Y%m%dT%H%M%S"; }  # [W4] 追加 Z 明确 UTC
ts_display() { echo "$1" | sed 's/T/ /;s/Z//'; }
get_readme_hash() { sha256sum "$README_PATH" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$README_PATH" 2>/dev/null | cut -d' ' -f1 || echo "unknown"; }
get_readme_lines() { wc -l < "$README_PATH" 2>/dev/null || echo "0"; }
# [W6] 检测 ggrep（macOS Homebrew GNU grep），如可用则优先使用
GREP_BIN="grep"
if command -v ggrep >/dev/null 2>&1; then
  GREP_BIN="ggrep"
elif ! echo "test" | grep -oP 'te' >/dev/null 2>&1; then
  GREP_BIN="grep"
fi
has_grep_P() { echo "test" | "$GREP_BIN" -oP 'te' >/dev/null 2>&1; }

init_backup_dir() {
  mkdir -p "$BACKUP_DIR" 2>/dev/null || {
    echo -e "${RED}[Error]${NC} 无法创建备份目录: $BACKUP_DIR"
    return 1
  }
  chmod 700 "$BACKUP_DIR" 2>/dev/null || true  # [C2] 备份目录仅当前用户可访问
  if [[ ! -f "$MANIFEST_FILE" ]]; then
    echo '{"version":"1.0","entries":[],"nextId":0}' > "$MANIFEST_FILE"
  fi
}

# --- manifest 操作 ---

read_manifest() {
  # 优先 JSON manifest，不存在则尝试文本 manifest 桥接
  if [[ -f "$MANIFEST_FILE" ]] && command -v jq &>/dev/null; then
    cat "$MANIFEST_FILE"
  elif [[ -f "$MANIFEST_TXT" ]]; then
    # 桥接：将 manifest.txt 转为 JSON entries
    local entries_json="["
    local first=true; local id=0; local skip_count=0
    while IFS='|' read -r ts op label lines hash; do
      [[ -z "$ts" ]] && continue
      $first && first=false || entries_json+=","
      # [C5] 字段数校验：跳过字段不完整的行
      if [[ -z "$op" || -z "$lines" || -z "$hash" ]]; then
        ((skip_count++))
        continue
      fi
      local escaped_label
      escaped_label=$(json_escape "$label")
      entries_json+="{\"id\":$id,\"timestamp\":\"$ts\",\"operation\":\"$op\",\"label\":\"$escaped_label\",\"readmeLines\":$lines,\"readmeHash\":\"$hash\"}"
      ((id++))
    done < "$MANIFEST_TXT"
    entries_json+="]"
    [[ $skip_count -gt 0 ]] && echo -e "${YELLOW}⚠${NC} manifest.txt 中 $skip_count 行因字段不完整被跳过" >&2
    echo "{\"version\":\"1.0\",\"entries\":$entries_json,\"nextId\":$id}"
  else
    echo '{"version":"1.0","entries":[],"nextId":0}'
  fi
}

add_manifest_entry() {
  local operation="$1" label="${2:-}"
  local ts=$(timestamp)
  local lines=$(get_readme_lines)
  local hash=$(get_readme_hash)

  if command -v jq &>/dev/null; then
    local manifest=$(read_manifest)
    local next_id=$(echo "$manifest" | jq -r '.nextId')
    local new_entry=$(jq -n --argjson id "$next_id" --arg ts "$ts" --arg op "$operation" --arg label "$label" --argjson lines "$lines" --arg hash "$hash" \
      '{id: $id, timestamp: $ts, operation: $op, label: $label, readmeLines: $lines, readmeHash: $hash}')
    manifest=$(echo "$manifest" | jq --argjson entry "$new_entry" '.entries += [$entry] | .nextId += 1')
    # 原子写入：先写临时文件再 mv
    echo "$manifest" > "${MANIFEST_FILE}.tmp" && mv "${MANIFEST_FILE}.tmp" "$MANIFEST_FILE"
  else
    # [C4] 纯文本兜底：原子写入（cp + append + mv）
    cp "$MANIFEST_TXT" "${MANIFEST_TXT}.tmp" 2>/dev/null
    echo "$ts|$operation|$label|$lines|$hash" >> "${MANIFEST_TXT}.tmp"
    mv "${MANIFEST_TXT}.tmp" "$MANIFEST_TXT"
  fi
}

prune_old_backups() {
  # 保留最近 MAX_BACKUPS 个备份，同步删除 manifest 条目和对应文件
  local count=0
  if command -v jq &>/dev/null && [[ -f "$MANIFEST_FILE" ]]; then
    count=$(jq -r '.entries | length' "$MANIFEST_FILE" 2>/dev/null || echo 0)
  elif [[ -f "$MANIFEST_TXT" ]]; then
    count=$(wc -l < "$MANIFEST_TXT" 2>/dev/null || echo 0)
  fi
  if [[ "$count" -gt "$MAX_BACKUPS" ]]; then
    local excess=$((count - MAX_BACKUPS))
    # [I5] 始终输出清理信息，提高透明度
    echo -e "${BLUE}⏳${NC} 清理 $excess 个早期备份（含文件）..."
    local manifest=$(read_manifest)
    if command -v jq &>/dev/null; then
      # JSON manifest 路径：删除旧条目对应的备份文件，再裁剪 manifest
      local old_ts_list=$(echo "$manifest" | jq -r ".entries[:${excess}] | .[].timestamp" 2>/dev/null)
      for ts in $old_ts_list; do
        rm -f "${BACKUP_DIR}/${ts}_"*".md" 2>/dev/null || true
      done
      # 再裁剪 manifest
      echo "$manifest" | jq ".entries |= .[-${MAX_BACKUPS}:]" > "${MANIFEST_FILE}.tmp"
      mv "${MANIFEST_FILE}.tmp" "$MANIFEST_FILE"
    elif [[ -f "$MANIFEST_TXT" ]]; then
      # 纯文本 manifest 路径：删除前 excess 行对应的备份文件，再裁剪
      local line_num=0
      while IFS='|' read -r ts op label lines hash; do
        [[ -z "$ts" ]] && continue
        ((line_num++))
        [[ $line_num -le $excess ]] && rm -f "${BACKUP_DIR}/${ts}_"*".md" 2>/dev/null || true
      done < "$MANIFEST_TXT"
      tail -n "+$((excess + 1))" "$MANIFEST_TXT" > "${MANIFEST_TXT}.tmp"
      mv "${MANIFEST_TXT}.tmp" "$MANIFEST_TXT"
    fi
  fi
}

list_backups() {
  local manifest=$(read_manifest)
  local total_count=0  # [I6] 用于显示备份数/上限
  echo -e "${BOLD}备份列表（${BACKUP_DIR}）${NC}"
  echo ""

  if command -v jq &>/dev/null; then
    total_count=$(echo "$manifest" | jq -r '.entries | length')
    if [[ "$total_count" == "0" ]]; then
      echo "  （暂无备份）"
      return
    fi
    printf "  ${BOLD}%-6s %-21s %-18s %-6s %s${NC}\n" "编号" "时间" "操作" "行数" "标签"
    echo "  ------ --------------------- ------------------ ------ ----------"
    echo "$manifest" | jq -r '.entries | to_entries | .[] | "\(.key)\t\(.value.timestamp)\t\(.value.operation)\t\(.value.readmeLines)\t\(.value.label // "")"' | \
    while IFS=$'\t' read -r idx ts op lines label; do
      local ts_fmt=$(ts_display "$ts")
      local op_icon=""
      case "$op" in
        before-fix)  op_icon="🔧 before-fix" ;;
        after-fix)   op_icon="✅ after-fix" ;;
        before-undo) op_icon="↩ before-undo" ;;
        manual)      op_icon="📸 manual" ;;
        *)           op_icon="$op" ;;
      esac
      local tag=""; [[ -n "$label" ]] && tag="📝 $label"
      printf "  ${CYAN}[%-3s]${NC} %-21s %-18s %-6s %s\n" "$idx" "$ts_fmt" "$op_icon" "$lines" "$tag"
    done
  else
    # 无 jq：直接列出备份文件
    local found=false
    for f in "$BACKUP_DIR"/*.md; do
      [[ -f "$f" ]] || continue
      found=true
      local bn=$(basename "$f" .md)
      local lines=$(wc -l < "$f")
      echo "  ${CYAN}[?]${NC} $bn ($lines 行)"
      ((total_count++))
    done
    if ! $found; then echo "  （暂无备份）"; fi
    echo ""; echo -e "  ${YELLOW}提示：安装 jq 可启用编号选择和 diff 预览。${NC}"
  fi
  # [I6] 显示备份数/上限
  echo -e "  ${BOLD}备份数:${NC} $total_count/$MAX_BACKUPS"
  echo ""
}

# --- 备份操作 ---

create_backup() {
  local operation="$1" label="${2:-}"
  local ts=$(timestamp)
  # 并发安全：添加随机后缀避免同一秒内冲突
  local backup_file="${BACKUP_DIR}/${ts}_${RANDOM}_${operation}.md"

  init_backup_dir || return 1

  if [[ -f "$README_PATH" ]]; then
    # [I3] 原子写入：先 cp 到 .tmp 再 mv；[C1] 备份仅当前用户可读写
    cp "$README_PATH" "${backup_file}.tmp" && mv "${backup_file}.tmp" "$backup_file"
    chmod 600 "$backup_file" 2>/dev/null || true
    add_manifest_entry "$operation" "$label"
    prune_old_backups
    if [[ "$VERBOSE" == true ]]; then
      echo -e "${GREEN}✓${NC} 已备份: ${backup_file##*/} ($(get_readme_lines) 行)"
    fi
  else
    echo -e "${RED}✗${NC} README.md 不存在，无法备份"
    return 1
  fi
}

# --- 回滚操作 ---

do_undo() {
  local target_id="${1:-}"

  init_backup_dir || return 1
  local manifest=$(read_manifest)

  if ! command -v jq &>/dev/null; then
    echo -e "${RED}✗${NC} 回滚功能需要安装 jq。请运行: brew install jq / apt install jq"
    return 1
  fi

  local count=$(echo "$manifest" | jq -r '.entries | length')
  if [[ "$count" == "0" ]]; then
    echo "没有可用的备份。"
    return 0
  fi

  # 自动选择：最近的非 after-* 备份
  if [[ -z "$target_id" ]]; then
    target_id=$(echo "$manifest" | jq -r '[.entries[] | select(.operation != "after-fix" and .operation != "after-init" and .operation != "after-undo")] | last | .id // empty')
    [[ -z "$target_id" ]] && target_id=$(echo "$manifest" | jq -r '.entries[-1].id // empty')
  fi

  local entry=$(echo "$manifest" | jq -r ".entries[] | select(.id == $target_id)")
  if [[ -z "$entry" ]]; then
    echo -e "${RED}✗${NC} 未找到编号为 $target_id 的备份。使用 --undo --list 查看。"
    return 1
  fi

  local ts=$(echo "$entry" | jq -r '.timestamp')
  local op=$(echo "$entry" | jq -r '.operation')
  local lines=$(echo "$entry" | jq -r '.readmeLines')
  local label=$(echo "$entry" | jq -r '.label // ""')
  local backup_file="${BACKUP_DIR}/${ts}_"*"_${op}.md"
  # 通配符展开
  backup_file=$(ls $backup_file 2>/dev/null | head -1)
  # [Phase D Fix] glob 歧义防护：如匹配到多个文件（RANDOM 碰撞），按 manifest hash 校验选择正确文件
  local match_count=$(ls ${BACKUP_DIR}/${ts}_*_${op}.md 2>/dev/null | wc -l)
  if [[ "$match_count" -gt 1 ]]; then
    local expected_hash=$(echo "$entry" | jq -r '.readmeHash // ""')
    for candidate in ${BACKUP_DIR}/${ts}_*_${op}.md; do
      local candidate_hash=$(sha256sum "$candidate" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$candidate" 2>/dev/null | cut -d' ' -f1)
      if [[ -n "$expected_hash" && "$candidate_hash" == "$expected_hash" ]]; then
        backup_file="$candidate"
        break
      fi
    done
  fi

  if [[ -z "$backup_file" || ! -f "$backup_file" ]]; then
    echo -e "${RED}✗${NC} 备份文件已丢失（manifest 记录存在但文件不存在）"
    return 1
  fi

  echo ""
  echo -e "将回滚到以下备份:"
  echo -e "  ${BOLD}时间：${NC}$(ts_display "$ts")"
  echo -e "  ${BOLD}操作：${NC}$op"
  echo -e "  ${BOLD}行数：${NC}$lines"
  [[ -n "$label" ]] && echo -e "  ${BOLD}标签：${NC}$label"
  echo ""

  # diff 预览
  local diff_lines=$(diff -u "$README_PATH" "$backup_file" 2>/dev/null | wc -l || echo "0")
  if [[ "$diff_lines" -gt 0 && "$diff_lines" -lt 200 ]]; then
    echo -e "${BOLD}变更预览（${diff_lines} 行 diff）：${NC}"
    diff -u "$README_PATH" "$backup_file" 2>/dev/null | head -50 || true
    echo ""
  fi

  # [C3] 回滚前备份当前状态——失败则中止回滚，除非 --force
  echo -e "${BLUE}⏳${NC} 回滚前备份当前状态..."
  if ! create_backup "before-undo" "" > /dev/null 2>&1; then
    if [[ "$FORCE_MODE" == true ]]; then
      echo -e "${YELLOW}⚠${NC} 回滚前备份失败（--force 模式跳过），当前状态未存档"
    else
      echo -e "${RED}✗${NC} 回滚前备份失败，中止回滚。请检查磁盘空间或使用 --force 强制回滚。"
      return 1
    fi
  fi

  # 确认
  echo -ne "确认恢复？[y/N] "
  read -r confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "已取消。"
    return 0
  fi

  # 原子覆写：先写临时文件再 mv，防止中断损坏 README.md
  local tmp_readme="${README_PATH}.tmp.$$"
  if cp "$backup_file" "$tmp_readme"; then
    mv "$tmp_readme" "$README_PATH"
  else
    echo -e "${RED}✗${NC} 恢复失败：无法写入临时文件"
    rm -f "$tmp_readme"
    return 1
  fi
  echo -e "${GREEN}✓${NC} 已恢复到备份 [$target_id]（当前状态已存档，可再次 --undo 撤销）"
}

# --- 差异查看 ---

do_diff_backup() {
  local target_id="${1:-}"
  init_backup_dir || return 1

  if ! command -v jq &>/dev/null; then
    echo -e "${YELLOW}⚠${NC} diff 预览需要 jq。使用 --undo --list 查看备份，手动对比文件："
    echo "  diff $BACKUP_DIR/<backup-file>.md $README_PATH"
    return 0
  fi

  local manifest=$(read_manifest)
  [[ -z "$target_id" ]] && target_id=$(echo "$manifest" | jq -r '.entries[-1].id // empty')
  local entry=$(echo "$manifest" | jq -r ".entries[] | select(.id == $target_id)")
  [[ -z "$entry" ]] && { echo -e "${RED}✗${NC} 未找到备份编号 $target_id"; return 1; }

  local ts=$(echo "$entry" | jq -r '.timestamp')
  local op=$(echo "$entry" | jq -r '.operation')
  local backup_file="${BACKUP_DIR}/${ts}_"*"_${op}.md"
  backup_file=$(ls $backup_file 2>/dev/null | head -1)

  [[ ! -f "$backup_file" ]] && { echo -e "${RED}✗${NC} 备份文件已丢失"; return 1; }

  echo -e "${BOLD}对比：备份 [$target_id] ($op, $(ts_display "$ts")) vs 当前 README${NC}"
  echo ""
  diff -u "$backup_file" "$README_PATH" 2>/dev/null | head -100 || echo "（无差异）"
}

# --- 复杂度评估 ---

do_complexity() {
  # [W1] --tier 手动覆盖：跳过自动评估，直接输出指定 Tier
  if [[ -n "$TIER_OVERRIDE" ]]; then
    local t=$TIER_OVERRIDE
    local tl="2Agent并行"
    [[ $t -eq 0 ]] && tl="单Agent串行"
    [[ $t -eq 2 ]] && tl="N Agent扇出"
    # [Phase D Fix] --tier --format json → 输出 JSON
    if [[ "$FORMAT" == "json" ]]; then
      local ts=$(timestamp)
      cat <<JSONEOF
{
  "version": "$VERSION",
  "timestamp": "$ts",
  "mode": "complexity",
  "tier": $t,
  "tierLabel": "$tl",
  "manualOverride": true
}
JSONEOF
      return 0
    fi
    echo "=== readme-alive 复杂度评估（手动指定） ==="
    echo "加权总分:   N/A → ${BOLD}--/10${NC}"
    echo "推荐 Tier:  $t ($tl)"
    return 0
  fi

  local file_count=0

  # 使用 -prune 排除大目录（性能关键：防止遍历 node_modules 等）
  file_count=$(find . \
    \( -path '*/node_modules' -o -path '*/.git' -o -path '*/target' -o -path '*/build' -o -path '*/dist' -o -path '*/vendor' -o -path '*/__pycache__' -o -path '*/.venv' -o -path '*/venv' -o -path '*/.idea' -o -path '*/.vscode' -o -path '*/.claude' -o -path '*/coverage' -o -path '*/.next' -o -path '*/.nuxt' -o -path '*/.output' -o -path '*/out' \) -prune \
    -o -type f \( -name '*.java' -o -name '*.py' -o -name '*.js' -o -name '*.ts' -o -name '*.jsx' -o -name '*.tsx' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.go' -o -name '*.rs' -o -name '*.yml' -o -name '*.yaml' -o -name '*.json' -o -name '*.toml' -o -name '*.xml' -o -name '*.properties' -o -name '*.md' -o -name '*.rst' -o -name '*.sh' -o -name '*.bash' -o -name '*.zsh' -o -name '*.cfg' -o -name '*.ini' -o -name '.env.example' -o -name 'Dockerfile' -o -name 'Makefile' -o -name 'CMakeLists.txt' -o -name 'build.gradle' -o -name 'build.gradle.kts' \) -print 2>/dev/null | wc -l)

  # 语言检测
  local langs="" lang_count=0
  # [W8] Java 检测要求构建文件 + src/main/java 目录，避免孤立 pom.xml 误判
  [[ -f "pom.xml" || -f "build.gradle" || -f "build.gradle.kts" ]] && [[ -d "src/main/java" ]] && { langs="$langs Java"; ((lang_count++)) || true; }
  [[ -f "package.json" ]] && { langs="$langs Node.js"; ((lang_count++)) || true; }
  [[ -f "go.mod" ]] && { langs="$langs Go"; ((lang_count++)) || true; }
  [[ -f "Cargo.toml" ]] && { langs="$langs Rust"; ((lang_count++)) || true; }
  [[ -f "pyproject.toml" || -f "setup.py" || -f "requirements.txt" ]] && { langs="$langs Python"; ((lang_count++)) || true; }

  # [I1] 纯脚本兜底：无构建文件时按扩展名统计推断主语言
  if [[ "$lang_count" -eq 0 ]]; then
    local py_count=$(find . -name '*.py' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null | wc -l)
    local sh_count=$(find . -name '*.sh' -o -name '*.bash' 2>/dev/null | wc -l)
    local js_count=$(find . -name '*.js' -not -path '*/node_modules/*' 2>/dev/null | wc -l)
    local rb_count=$(find . -name '*.rb' 2>/dev/null | wc -l)
    local max_count=$py_count; local inferred="Python"
    [[ $sh_count -gt $max_count ]] && { max_count=$sh_count; inferred="Shell"; }
    [[ $js_count -gt $max_count ]] && { max_count=$js_count; inferred="Node.js"; }
    [[ $rb_count -gt $max_count ]] && { max_count=$rb_count; inferred="Ruby"; }
    [[ $max_count -gt 0 ]] && { langs="[Inferred] $inferred"; lang_count=1; }
  fi

  # 模块计数（按语言适配）
  local module_count=1
  # Java/Maven: pom.xml <module> 标签
  if [[ -f "pom.xml" ]]; then
    local mc=$(grep -c '<module>' pom.xml 2>/dev/null) || mc=0
    [[ "$mc" -gt 0 ]] && module_count=$mc
  fi
  # Java/Gradle: settings.gradle include 指令
  if [[ -f "settings.gradle" || -f "settings.gradle.kts" ]]; then
    local gc=$(grep -cE 'include[[:space:]]*['"'"'"]' settings.gradle* 2>/dev/null) || gc=0
    [[ "$gc" -gt "$module_count" ]] && module_count=$gc
  fi
  # Node.js: package.json workspaces 或 src/ 顶层目录
  if [[ -f "package.json" ]] && command -v jq &>/dev/null; then
    local wc=$(jq '.workspaces | length' package.json 2>/dev/null) || wc=0
    [[ "$wc" -gt "$module_count" ]] && module_count=$wc
  elif [[ -f "package.json" ]]; then
    local nd=$(find src packages libs apps -maxdepth 1 -type d 2>/dev/null | wc -l) || nd=0
    [[ "$nd" -gt "$module_count" ]] && module_count=$nd
  fi
  # [W10] Python: 含 __init__.py 的顶层包目录（同时搜索根目录和 src/）
  if [[ -f "pyproject.toml" || -f "setup.py" ]]; then
    local pd=$(find . src -maxdepth 2 -name '__init__.py' -not -path '*/tests/*' 2>/dev/null | wc -l) || pd=0
    [[ "$pd" -gt "$module_count" ]] && module_count=$pd
  fi
  # [W10] Go: go.mod/main.go 所在目录（避免 -exec test fork 开销）
  if [[ -f "go.mod" ]]; then
    local gd=$(find . -maxdepth 2 \( -name 'go.mod' -o -name 'main.go' \) -not -path '*/internal*' -not -path '*/vendor*' -not -path '*/.git/*' 2>/dev/null | sed 's|/[^/]*$||' | sort -u | wc -l) || gd=0
    [[ "$gd" -gt "$module_count" ]] && module_count=$gd
  fi
  # [C8] Rust: Cargo.toml workspace members（从 members 数组提取实际条目数）
  if [[ -f "Cargo.toml" ]]; then
    if grep -q '\[workspace\]' Cargo.toml 2>/dev/null; then
      # 提取 members = [...] 中逗号分隔的成员条目数
      # [Phase D Fix] 支持单行+多行 TOML members 数组：先合并续行再提取成员
      local rmc=$(sed -n '/\[workspace\]/,/^\[/p' Cargo.toml 2>/dev/null | tr '\n' ' ' | grep -oP 'members\s*=\s*\[(.*?)\]' | tr ',' '\n' | grep -oP '"[^"]*"' | wc -l) || rmc=0
      [[ "$rmc" -gt "$module_count" ]] && module_count=$rmc
    else
      # [I7] 无 workspace 的单 crate 项目：统计 src/ 下 .rs 文件数作为模块数
      local rsc=$(find src -name '*.rs' -type f 2>/dev/null | wc -l) || rsc=0
      [[ "$rsc" -gt "$module_count" ]] && module_count=$rsc
    fi
  fi

  # [W9] 项目类型评分——多信号 Monorepo 检测
  local proj_type="单体"
  local proj_score=1
  local monorepo_signals=0
  # 信号1: 模块数 > 2
  [[ "$module_count" -gt 2 ]] && ((monorepo_signals++))
  # 信号2: 存在 lerna.json / nx.json / turbo.json
  [[ -f "lerna.json" || -f "nx.json" || -f "turbo.json" ]] && ((monorepo_signals++))
  # 信号3: 存在多个 package.json（排除 node_modules）
  local pkg_count=$(find . -name 'package.json' -not -path '*/node_modules/*' 2>/dev/null | wc -l)
  [[ "$pkg_count" -gt 1 ]] && ((monorepo_signals++))
  # 信号4: 存在多个 go.mod
  local gomod_count=$(find . -name 'go.mod' -not -path '*/vendor/*' 2>/dev/null | wc -l)
  [[ "$gomod_count" -gt 1 ]] && ((monorepo_signals++))
  # 信号5: 存在多个 Cargo.toml
  local cargo_count=$(find . -name 'Cargo.toml' -not -path '*/target/*' -not -path '*/.git/*' 2>/dev/null | wc -l)
  [[ "$cargo_count" -gt 1 ]] && ((monorepo_signals++))
  [[ $monorepo_signals -ge 2 ]] && { proj_type="Monorepo"; proj_score=10; }
  [[ "$proj_score" -lt 7 ]] && [[ -f "package.json" ]] && grep -q '"workspaces"' package.json 2>/dev/null && { proj_type="多包"; proj_score=7; }
  [[ "$proj_score" -lt 5 ]] && [[ -f "vite.config.js" || -f "vite.config.ts" || -d "frontend" ]] && { proj_type="单体+前端"; proj_score=5; }

  # README 行数
  local readme_lines=0
  [[ -f "$README_PATH" ]] && readme_lines=$(wc -l < "$README_PATH")

  # 加权评分（使用 awk 做浮点运算，bc 不可用时兜底）
  local raw fscore mscore lscore rscore

  # 文件数→分数（1-10）
  if   [[ $file_count -gt 10000 ]]; then fscore=10
  elif [[ $file_count -gt 5000  ]]; then fscore=9
  elif [[ $file_count -gt 2000  ]]; then fscore=8
  elif [[ $file_count -gt 1000  ]]; then fscore=7
  elif [[ $file_count -gt 500   ]]; then fscore=6
  elif [[ $file_count -gt 300   ]]; then fscore=5  # [C7] 对齐规范 300-500→5
  elif [[ $file_count -gt 100   ]]; then fscore=4
  elif [[ $file_count -gt 50    ]]; then fscore=3
  elif [[ $file_count -gt 20    ]]; then fscore=2
  else fscore=1; fi

  # 模块数→分数（1-10）
  if   [[ $module_count -gt 100 ]]; then mscore=10
  elif [[ $module_count -gt 50  ]]; then mscore=9
  elif [[ $module_count -gt 30  ]]; then mscore=8
  elif [[ $module_count -gt 20  ]]; then mscore=7
  elif [[ $module_count -gt 12  ]]; then mscore=6
  elif [[ $module_count -gt 8   ]]; then mscore=5
  elif [[ $module_count -gt 5   ]]; then mscore=4
  elif [[ $module_count -gt 3   ]]; then mscore=3
  elif [[ $module_count -gt 1   ]]; then mscore=2
  else mscore=1; fi

  # 语言数→分数（1-10）
  if   [[ $lang_count -ge 4 ]]; then lscore=10
  elif [[ $lang_count -eq 3 ]]; then lscore=7
  elif [[ $lang_count -eq 2 ]]; then lscore=4
  else lscore=1; fi

  # [C9] README 行数→分数（规范: <50→1, 50-100→2, 100-200→3, 200-400→5, 400-800→7, >800→10）
  if   [[ $readme_lines -ge 800 ]]; then rscore=10
  elif [[ $readme_lines -ge 400 ]]; then rscore=7
  elif [[ $readme_lines -ge 200 ]]; then rscore=5
  elif [[ $readme_lines -ge 100 ]]; then rscore=3
  elif [[ $readme_lines -ge 50   ]]; then rscore=2
  else rscore=1; fi  # [C6] 0行或 <50 行均得 1 分，防止未赋值崩溃
  [[ -z "$rscore" ]] && rscore=1  # [C6] 防御：确保 rscore 永不空

  if command -v bc &>/dev/null; then
    raw=$(echo "scale=1; $fscore*0.35 + $mscore*0.20 + $lscore*0.20 + $proj_score*0.15 + $rscore*0.10" | bc)
  else
    raw=$(awk "BEGIN { printf \"%.1f\", $fscore*0.35 + $mscore*0.20 + $lscore*0.20 + $proj_score*0.15 + $rscore*0.10 }")
  fi
  local complexity=$(printf "%.0f" "$raw" 2>/dev/null || echo "$raw" | awk '{printf "%.0f", $1}')
  [[ -z "$complexity" || "$complexity" -lt 1 ]] && complexity=1
  [[ "$complexity" -gt 10 ]] && complexity=10

  # [W7] 边界缓冲：raw 在 3.0-3.9 或 6.0-6.9 区间时检查辅助信号
  local raw_int=$(printf "%.0f" "$raw" 2>/dev/null || echo "0")
  if command -v bc &>/dev/null; then
    local in_boundary=$(echo "($raw >= 3.0 && $raw < 4.0) || ($raw >= 6.0 && $raw < 7.0)" | bc 2>/dev/null) || in_boundary=0
  else
    local in_boundary=$(awk "BEGIN { if (($raw >= 3.0 && $raw < 4.0) || ($raw >= 6.0 && $raw < 7.0)) print 1; else print 0 }")
  fi
  if [[ "$in_boundary" == "1" ]]; then
    local aux_signals=0
    # 辅助信号1：存在 CI 配置
    [[ -f ".github/workflows"* || -f ".gitlab-ci.yml" || -f "Jenkinsfile" || -f ".circleci/config.yml" ]] && ((aux_signals++)) || true
    # 辅助信号2：近30天有 commits
    if command -v git &>/dev/null && git log --since="30 days ago" --oneline 2>/dev/null | head -1 | grep -q .; then
      ((aux_signals++)) || true
    fi
    # 辅助信号3：README > 200 行
    [[ "$readme_lines" -gt 200 ]] && ((aux_signals++)) || true
    # ≥2 个信号时向上调整 Tier
    if [[ $aux_signals -ge 2 ]]; then
      complexity=$((complexity + 1))
      [[ $complexity -gt 10 ]] && complexity=10
    fi
  fi

  local tier=1 tier_label="2Agent并行"
  [[ $complexity -le 3 ]] && { tier=0; tier_label="单Agent串行"; }
  [[ $complexity -ge 7 ]] && { tier=2; tier_label="N Agent扇出"; }

  # [W2] JSON 格式输出
  if [[ "$FORMAT" == "json" ]]; then
    json_output_complexity
    return 0
  fi

  echo "=== readme-alive 复杂度评估 ==="
  echo "源码文件数: $file_count  (分: $fscore)"
  echo "检测到语言: ${langs:-未知} (共 $lang_count 种, 分: $lscore)"
  echo "模块数:     $module_count  (分: $mscore)"
  echo "项目类型:   $proj_type  (分: $proj_score)"
  echo "README 行数: $readme_lines  (分: $rscore)"
  echo "---"
  echo "加权总分:   $raw → ${BOLD}$complexity/10${NC}"
  echo "推荐 Tier:  $tier ($tier_label)"
}

# --- 基础检查 ---

check_links() {
  local broken=0 links=""
  if has_grep_P; then
    # [W6] 使用 $GREP_BIN 确保跨平台 grep -P 支持
    links=$("$GREP_BIN" -oP '\[([^\]]*)\]\(([^)]*)\)' "$README_PATH" 2>/dev/null | "$GREP_BIN" -oP '(?<=\()[^)]+' | grep -v '^http' | grep -v '^#' | grep -v '^mailto:' || true)
  else
    # 无 -P 兜底：用基本正则提取
    links=$(grep -o '\[.*\]([^)]*' "$README_PATH" 2>/dev/null | sed 's/.*(//' | grep -v '^http' | grep -v '^#' | grep -v '^mailto:' || true)
  fi

  for link in $links; do
    if [[ ! -e "$link" ]]; then
      [[ "$VERBOSE" == true ]] && echo -e "  ${RED}✗${NC} 断链: $link"
      ((broken++)) || true
    fi
  done

  [[ $broken -gt 0 ]] && echo -e "${RED}[Critical]${NC} 发现 $broken 个断链" && return 1
  return 0
}

check_sections() {
  local missing=0
  local patterns=("快速开始|Getting Started|Quick Start" "安装|Install" "使用|Usage" "许可证|License")

  for pattern in "${patterns[@]}"; do
    if ! grep -qE "^#+\s*.*($pattern)" "$README_PATH" 2>/dev/null; then
      [[ "$VERBOSE" == true ]] && echo -e "  ${BLUE}i${NC} 建议添加章节: $pattern"
      json_add_finding "info" "缺少章节" "建议添加章节包含关键词: $pattern" ""
      ((JSON_INFO_COUNT++)) || true
      ((missing++)) || true
    fi
  done

  [[ $missing -gt 0 ]] && echo -e "${BLUE}[Info]${NC} 缺少 $missing 个建议章节"
  return 0  # Info 级别，永不返回错误
}

check_files() {
  # 性能优化：一次 find 构建文件索引，避免 N 次 find
  local missing=0
  # [W3] 安全 mktemp：多级回退，避免可预测路径
  local file_index=$(mktemp -t readme-alive-files-XXXXXX 2>/dev/null || mktemp "${TMPDIR:-/tmp}"/readme-alive-files.XXXXXX 2>/dev/null || echo "/tmp/readme-alive-files-$$-${RANDOM}")
  find . -type f -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null | sed 's|^\./||' > "$file_index"

  local refs
  if has_grep_P; then
    # [W6] 使用 $GREP_BIN
    refs=$("$GREP_BIN" -oP '`([a-zA-Z0-9_\-./]+\.(java|py|js|ts|go|rs|yml|yaml|json|xml|md|sh))`' "$README_PATH" 2>/dev/null | sed 's/`//g' || true)
  else
    refs=$(grep -oE '`[a-zA-Z0-9_\-./]+\.(java|py|js|ts|go|rs|yml|yaml|json|xml|md|sh)`' "$README_PATH" 2>/dev/null | sed 's/`//g' || true)
  fi

  for file in $refs; do
    local fname=$(basename "$file")
    if ! grep -q "/${fname}$" "$file_index" 2>/dev/null; then
      [[ "$VERBOSE" == true ]] && echo -e "  ${YELLOW}⚠${NC} 引用文件可能不存在: $file"
      json_add_finding "warning" "文件引用" "引用文件可能不存在: $file" ""
      ((JSON_WARNING_COUNT++)) || true
      ((missing++)) || true
    fi
  done

  rm -f "$file_index"
  [[ $missing -gt 0 ]] && echo -e "${YELLOW}[Warning]${NC} $missing 个引用文件可能不存在"
  return 0
}

check_structure() {
  local missing=0 dirs=""
  if has_grep_P; then
    # [W6] 使用 $GREP_BIN
    dirs=$("$GREP_BIN" -oP '`?([a-zA-Z0-9_\-]+/)`?' "$README_PATH" 2>/dev/null | sed 's/`//g' | sort -u || true)
  else
    dirs=$(grep -oE '`?[a-zA-Z0-9_\-]+/`?' "$README_PATH" 2>/dev/null | sed 's/`//g' | sort -u || true)
  fi

  for dir in $dirs; do
    local clean_dir="${dir%/}"
    [[ -z "$clean_dir" || "$clean_dir" == "src" || "$clean_dir" == "docs" ]] && continue
    if [[ ! -d "$clean_dir" ]]; then
      [[ "$VERBOSE" == true ]] && echo -e "  ${RED}✗${NC} README 引用的目录不存在: $clean_dir/"
      ((missing++)) || true
    fi
  done

  [[ $missing -gt 0 ]] && echo -e "${RED}[Critical]${NC} README 引用了 $missing 个不存在的目录" && return 1
  return 0
}

# --- AI 功能桩 ---

do_fix() {
  echo "readme-alive --fix 需要 AI Skill 环境支持。"
  echo "CLI 模式下仅支持基础检查（--check），不支持自动修复。"
  echo "请在 Claude Code 中运行 /readme-alive --fix。"
}

# --- 帮助 ---

usage() {
  cat <<EOF
${BOLD}readme-alive CLI v${VERSION}${NC} — README 质量守护工具

${BOLD}用法:${NC}
  $0                         默认：基础检查
  $0 --ci                    CI 模式（Critical 问题则 exit 1）
  $0 --check <dim>           仅检查特定维度 (links|sections|files|structure|all)
  $0 --complexity            输出复杂度评估
  $0 --backup [label]        手动创建备份快照
  $0 --undo [id]             回滚到指定备份（默认最近）
  $0 --undo --list           列出所有备份
  $0 --diff-backup [id]      对比当前 README 与备份的差异
  $0 --fix                   AI 智能修复（需 Claude Code 环境）
  $0 --verbose               详细输出
  $0 --help                  显示帮助

${BOLD}AI 功能（需在 Claude Code 中通过 /readme-alive 使用）：${NC}
  /readme-alive              完整审计（含语义分析）
  /readme-alive --fix         智能段落修复（无锚点，不留痕迹）
  /readme-alive --full        全量扫描

${BOLD}备份说明：${NC}
  备份存储在 ${BACKUP_BASE}/
  自动保留最近 ${MAX_BACKUPS} 个备份，超出自动清理
EOF
  exit 0
}

# --- 主入口 ---

main() {
  local mode="check" check_dim="all" backup_label="" undo_id="" diff_id=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      --ci)        CI_MODE=true; shift ;;
      --verbose)   VERBOSE=true; shift ;;
      --format)    FORMAT="$2"; shift 2 ;;
      --check)     mode="check"; check_dim="$2"; shift 2 ;;
      --complexity) mode="complexity"; shift ;;
      --backup)    mode="backup"; backup_label="${2:-}"; [[ "${2:-}" != --* && -n "${2:-}" ]] && shift 2 || shift ;;
      --undo)
        if [[ "${2:-}" == "--list" ]]; then mode="list-backups"; shift 2
        elif [[ "${2:-}" =~ ^[0-9]+$ ]]; then mode="undo"; undo_id="$2"; shift 2
        else mode="undo"; undo_id=""; shift; fi ;;
      --diff-backup)
        if [[ "${2:-}" =~ ^[0-9]+$ ]]; then mode="diff-backup"; diff_id="$2"; shift 2
        else mode="diff-backup"; diff_id=""; shift; fi ;;
      --fix)       mode="fix"; shift ;;
      --force)     FORCE_MODE=true; shift ;;  # [C3] 强制模式
      --tier)      TIER_OVERRIDE="$2"; shift 2 ;;  # [W1] 手动指定复杂度等级
      --dry-run)   DRY_RUN=true; shift ;;
      --help)      usage ;;
      *)           echo "未知选项: $1"; usage ;;
    esac
  done

  # [W1] TIER_OVERRIDE 校验（合法值 0/1/2）
  if [[ -n "$TIER_OVERRIDE" ]]; then
    if [[ ! "$TIER_OVERRIDE" =~ ^[012]$ ]]; then
      echo -e "${RED}[Error]${NC} --tier 仅接受 0、1 或 2，收到: $TIER_OVERRIDE"
      exit 2
    fi
  fi

  case $mode in
    check)
      # [W2] JSON 格式：调用专用输出函数
      if [[ "$FORMAT" == "json" ]]; then
        [[ -f "$README_PATH" ]] || { echo '{"error":"README.md not found"}'; exit 2; }
        local critical=0
        case $check_dim in
          all)
            check_links && true || { local rc=$?; [[ $rc -eq 1 ]] && ((critical++)) || true; }
            check_structure && true || { local rc=$?; [[ $rc -eq 1 ]] && ((critical++)) || true; }
            check_files && true || true
            check_sections && true || true
            ;;
          links)     check_links && true || { local rc=$?; [[ $rc -eq 1 ]] && ((critical++)) || true; } ;;
          structure) check_structure && true || { local rc=$?; [[ $rc -eq 1 ]] && ((critical++)) || true; } ;;
          files)     check_files && true || true ;;
          sections)  check_sections && true || true ;;
        esac
        json_output_check "$critical"
        exit 0
      fi

      echo "=== readme-alive CLI v${VERSION} ==="
      [[ -f "$README_PATH" ]] || { echo -e "${RED}[Error]${NC} README.md 不存在"; exit 2; }
      echo "README: $README_PATH"
      echo ""

      local critical=0
      case $check_dim in
        all)
          # [I2] 统一为 $rc 检查模式
          check_links && true || { local rc=$?; [[ $rc -eq 1 ]] && ((critical++)) || true; }
          check_structure && true || { local rc=$?; [[ $rc -eq 1 ]] && ((critical++)) || true; }
          check_files && true || true
          check_sections && true || true
          ;;
        links)     check_links && true || { local rc=$?; [[ $rc -eq 1 ]] && ((critical++)) || true; } ;;
        structure) check_structure && true || { local rc=$?; [[ $rc -eq 1 ]] && ((critical++)) || true; } ;;
        files)     check_files && true || true ;;
        sections)  check_sections && true || true ;;
      esac

      echo ""
      echo "审计结果: 🔴$critical  🟡0  🔵0"
      [[ "$CI_MODE" == true && $critical -gt 0 ]] && exit 1
      ;;
    complexity) do_complexity ;;  # [W2] JSON 输出由 do_complexity 内部处理
    backup)
      [[ -f "$README_PATH" ]] || { echo -e "${RED}✗${NC} README.md 不存在"; exit 2; }
      create_backup "manual" "$backup_label"
      echo -e "${GREEN}✓${NC} 快照已创建${backup_label:+（标签: $backup_label）}"
      ;;
    undo) do_undo "$undo_id" ;;
    list-backups) list_backups ;;
    diff-backup) do_diff_backup "$diff_id" ;;
    fix) do_fix ;;
  esac
}

main "$@"