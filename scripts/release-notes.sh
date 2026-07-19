#!/usr/bin/env bash
#
# 从 conventional commits 生成 release 正文。
#
# 为什么不用 GitHub 的 generate_release_notes:它只列**已合并的 PR**。本仓库是
# 直接往 main 提交的,没有 PR,于是生成结果永远只有一行 "Full Changelog: <链接>"
# —— 更新弹窗里等于什么都没说。而本仓库的提交信息是规范的 conventional commits
# (实测最近 30 条 100% 符合),按类型归类就能得到真正有用的说明。
#
# 输出刻意只用「标题 / 无序列表 / 行内粗体 / 链接」这几种 Markdown —— App 内的
# ReleaseNotesParser 只认这些,用 HTML(如 <details>)会被原样显示成标签。
#
# 用法: scripts/release-notes.sh v1.3.2 [上一个 tag]
# 本地预览: scripts/release-notes.sh v1.3.2

set -euo pipefail

TAG="${1:?用法: release-notes.sh <tag> [prev-tag]}"
PREV="${2:-}"

if [ -z "$PREV" ]; then
    # 取 TAG 之前最近的一个 tag;首个版本时为空
    PREV="$(git describe --tags --abbrev=0 "${TAG}^" 2>/dev/null || true)"
fi

if [ -n "$PREV" ]; then
    RANGE="${PREV}..${TAG}"
else
    RANGE="$TAG"
fi

REPO_URL="$(git config --get remote.origin.url \
    | sed -E 's#^git@github\.com:#https://github.com/#; s#\.git$##')"

# 取范围内所有非 merge 提交的标题
subjects() { git log --no-merges --pretty=format:'%s' "$RANGE"; }

# 把 "type(scope): 说明" 转成 "- **scope**: 说明";无 scope 则 "- 说明"。
# 注:macOS 自带 bash 3.2 没有关联数组,这里用多次过滤代替按类型分桶。
render() {
    local types="$1"
    subjects \
        | grep -E "^(${types})(\([^)]+\))?!?: " \
        | sed -E "s/^[a-z]+\(([^)]+)\)!?: /- **\1**: /; s/^[a-z]+!?: /- /"
}

# 破坏性变更单独提到最前:conventional commits 用 type 后的 "!" 标记
breaking() {
    subjects | grep -E '^[a-z]+(\([^)]+\))?!: ' \
        | sed -E "s/^[a-z]+\(([^)]+)\)!: /- **\1**: /; s/^[a-z]+!: /- /" || true
}

# 先全部算好再统一输出。不能用 OUT+="$(emit ...)" 累加:命令替换会吃掉结尾
# 换行,段落之间就粘成 "...targets## 修复"。
BREAKING="$(breaking)"
FEAT="$(render 'feat' || true)"
FIX="$(render 'fix' || true)"
PERF="$(render 'perf' || true)"
REFACTOR="$(render 'refactor' || true)"

# 只有内部改动(测试/文档/构建等)时不要留空 —— 空正文会让更新弹窗显示
# 「本次发布未附更新说明」,对维护性发版是误导。
OTHER=""
if [ -z "${FEAT}${FIX}${PERF}${REFACTOR}${BREAKING}" ]; then
    OTHER="$(render 'test|docs|chore|ci|build|style' || true)"
fi

section() {
    [ -n "$2" ] && printf '## %s\n%s\n\n' "$1" "$2"
    return 0
}

section '⚠️ 破坏性变更' "$BREAKING"
section '新增' "$FEAT"
section '修复' "$FIX"
section '性能' "$PERF"
section '优化' "$REFACTOR"
section '其他改动' "$OTHER"

if [ -z "${BREAKING}${FEAT}${FIX}${PERF}${REFACTOR}${OTHER}" ]; then
    printf '本次发布无代码变更。\n\n'
fi

if [ -n "$PREV" ] && [ -n "$REPO_URL" ]; then
    printf '**Full Changelog**: %s/compare/%s...%s\n' "$REPO_URL" "$PREV" "$TAG"
fi
