#!/usr/bin/env bash
# 发布一个新版本的补丁。
#
# 用法：
#   ./publish.sh <批次交付目录> [tag]
#
# 例：
#   ./publish.sh ../../_kb/out/delivery_c10w2 v20261001
#
# 做四件事：
#   ① 校验交付目录（必须来自 batch export，含 delivery.json）
#   ② 只同步 patch/ 下的 .json（不碰 README、不碰你手写的任何东西）
#   ③ 打印将被覆盖/新增/删除的文件清单，并同步
#   ④ 提交 + 打 tag（不自动 push，推送要你自己确认）
#
# 设计原则：
#   - 历史版本靠 git tag 保留，所以同步时**允许删除**本版不再需要的旧文件，
#     这样 patch/ 始终等于最新一版的完整交付集，不会越积越乱。
#   - 但删除前一定列出来，让你过目。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${1:-}"
TAG="${2:-}"

die() { echo "❌ $*" >&2; exit 1; }

[ -n "$SRC" ] || die "用法：./publish.sh <批次交付目录> [tag]
   例：./publish.sh ../../_kb/out/delivery_c10w2 v20261001"
[ -d "$SRC" ] || die "交付目录不存在：$SRC"

# ── ① 校验来源：必须是 batch export 的产物
DELIV="$SRC/delivery.json"
[ -f "$DELIV" ] || die "交付目录里没有 delivery.json —— 这不是 batch.py export 的输出，拒绝发布。
   （直接手攒的目录没有验收记录，不能当发布源。）"
SRCPATCH="$SRC/patch"
[ -d "$SRCPATCH" ] || die "交付目录里没有 patch/ 子目录：$SRCPATCH"

echo "来源：$SRC"
python3 - "$DELIV" <<'PY'
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
for k in ('source_snapshot','new_snapshot','created_at'):
    if d.get(k): print(f"  {k}: {d[k]}")
for k in ('retired','excluded'):
    v=d.get(k) or []
    if v: print(f"  {k}: {len(v)} 项（不进入本次补丁）")
PY

# ── ② 校验：交付目录里不能混入非 JSON 的内容（防误带字体、二进制等）
BAD=$(find "$SRCPATCH" -type f ! -name '*.json' | head -20 || true)
if [ -n "$BAD" ]; then
  echo "⚠️ 交付目录里有非 .json 文件，将被忽略："
  echo "$BAD" | sed 's/^/    /'
fi

# ── ③ 计算差异并同步
echo
echo "=== 将同步到 patch/ ==="
ADDED=0; CHANGED=0
while IFS= read -r -d '' f; do
  rel="${f#"$SRCPATCH"/}"
  dst="$REPO/patch/$rel"
  if [ ! -e "$dst" ]; then echo "  ＋ 新增 $rel"; ADDED=$((ADDED+1))
  elif ! cmp -s "$f" "$dst"; then echo "  ✎ 更新 $rel"; CHANGED=$((CHANGED+1)); fi
done < <(find "$SRCPATCH" -type f -name '*.json' -print0)

DELETED=0
if [ -d "$REPO/patch" ]; then
  while IFS= read -r -d '' f; do
    rel="${f#"$REPO/patch"/}"
    [ "$rel" = "README.md" ] && continue
    case "$rel" in *.json) ;; *) continue ;; esac
    if [ ! -e "$SRCPATCH/$rel" ]; then echo "  － 移除 $rel（本版不再需要，旧版仍在 git tag 里）"; DELETED=$((DELETED+1)); fi
  done < <(find "$REPO/patch" -type f -print0)
fi

if [ $((ADDED+CHANGED+DELETED)) -eq 0 ]; then
  echo "  （无变化——交付内容与当前 patch/ 完全一致）"
fi
echo
echo "小计：新增 $ADDED / 更新 $CHANGED / 移除 $DELETED"
read -r -p "确认同步？[y/N] " ans
[ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "已取消。"; exit 0; }

# 同步：先清掉旧的 .json，再拷新的，保证 patch/ 完全等于本版交付集
find "$REPO/patch" -type f -name '*.json' -delete
while IFS= read -r -d '' f; do
  rel="${f#"$SRCPATCH"/}"
  mkdir -p "$REPO/patch/$(dirname "$rel")"
  cp -p "$f" "$REPO/patch/$rel"
done < <(find "$SRCPATCH" -type f -name '*.json' -print0)

N=$(find "$REPO/patch" -type f -name '*.json' | wc -l)
echo "✅ 已同步 $N 个文件到 patch/"

# ── ④ 提交与打 tag（不自动 push）
cd "$REPO"
git add -A patch
if git diff --cached --quiet; then
  echo "ℹ️  git 里没有变化，跳过提交"
else
  MSG="发布补丁：$N 个文件"
  [ -n "$TAG" ] && MSG="$MSG（$TAG）"
  git commit -q -m "$MSG"
  echo "✅ 已提交"
fi

if [ -n "$TAG" ]; then
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "⚠️ tag $TAG 已存在，跳过"
  else
    git tag -a "$TAG" -m "补丁发布 $TAG（$N 个文件）"
    echo "✅ 已打 tag：$TAG"
  fi
fi

echo
echo "下一步（需要你确认后手动执行）："
echo "    git push origin main${TAG:+ && git push origin $TAG}"
echo
echo "别忘了在 CHANGELOG.md 里追加一行版本记录。"
