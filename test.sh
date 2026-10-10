#!/bin/sh
# arboré の create / remove を一時リポジトリで検証する。Docker は不要（docker を差し替える）。
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
arbore="$here/bin/arboré"
tmp="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/arbore-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fail=0
check() { if eval "$2"; then echo "  ok: $1"; else echo "  NG: $1"; fail=1; fi; }

# docker compose config は正規化済みの JSON を返すだけにして、down は呼ばれたプロジェクトを記録する。
# コンテナは "プロジェクト<TAB>working_dir" の行で表し、ps はラベルの filter に応じて引く
mkdir -p "$tmp/bin"
: > "$tmp/containers"
cat > "$tmp/bin/docker" <<EOF
#!/bin/sh
st="$tmp/containers"
if [ "\$1" = ps ]; then
  f=; for a; do case "\$a" in label=*) f="\${a#label=}" ;; esac; done
  case "\$f" in
    com.docker.compose.project.working_dir=*) awk -F'\t' -v v="\${f#*=}" '\$2 == v { print \$1 }' "\$st" ;;
    com.docker.compose.project=*) awk -F'\t' -v v="\${f#*=}" '\$1 == v { print \$2 }' "\$st" ;;
    *) cut -f2 "\$st" ;;
  esac
  exit 0
fi
case "\$2" in
  -p) echo "\$3" >> "$tmp/down.log"
      awk -F'\t' -v v="\$3" '\$1 != v' "\$st" > "\$st.new" && mv "\$st.new" "\$st" ;;
  config) cat <<'JSON'
{"name":"fixed","services":{
  "web":{"container_name":"proxy","ports":[
    {"target":80,"published":"8080"},
    {"host_ip":"127.0.0.1","target":81,"published":"18080-18081"},
    {"target":9000}]},
  "worker":{"image":"busybox"}}}
JSON
  ;;
esac
EOF
chmod +x "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# コンテナを起動したことにする
up() { printf '%s\t%s\n' "$1" "$2" >> "$tmp/containers"; }

cd "$tmp" && mkdir proj && cd proj && git init -q
printf 'services: {}\n' > docker-compose.yaml
printf '.env\n' > .gitignore
printf '.env\nREADME\n' > .worktreeinclude
git add . && git commit -qm init
echo SECRET=1 > .env
touch README

echo "create"
"$arbore" create feature/x >/dev/null 2>&1
wt="$tmp/proj.feature-x"
ov="$wt/docker-compose.override.yaml"
check "worktree ができる" '[ -d "$wt" ]'
check "ブランチ名はそのまま" '[ "$(git -C "$wt" branch --show-current)" = feature/x ]'
check "gitignore された .worktreeinclude の対象をコピーする" '[ -f "$wt/.env" ]'
check "ignore されていないものはコピーしない" '[ ! -e "$wt/README" ]'
check "プロジェクト名を上書きする" 'grep -q "\"name\": \"proj-feature-x\"" "$ov"'
check "container_name に接頭辞" 'grep -q "\"proj-feature-x-proxy\"" "$ov"'
check "ports は !override" 'grep -q "\"ports\": !override \[" "$ov"'
check "ポートは +1000" 'grep -q "\"9080\"" "$ov" && grep -q "\"19080-19081\"" "$ov"'
check "元のポートは残らない" '! grep -q "\"8080\"" "$ov"'
check "ports の無いサービスは書かない" '! grep -q worker "$ov"'
check "list に出る" '[ "$("$arbore" list)" = feature-x ]'
check "dir でパスを返す" '[ "$("$arbore" dir feature/x)" = "$wt" ]'
check "dir は無ければ失敗" '! "$arbore" dir nothing >/dev/null 2>&1'
check "dir は引数なしで本体を返す" '[ "$(cd "$wt" && "$arbore" dir)" = "$tmp/proj" ]'

"$arbore" create y >/dev/null 2>&1
check "2 つ目は +2000" 'grep -q "\"10080\"" "$tmp/proj.y/docker-compose.override.yaml"'

mv .worktreeinclude .wi
echo n | "$arbore" create no-inc >/dev/null 2>&1
check ".worktreeinclude が無く n ならコピーしない" '[ ! -e "$tmp/proj.no-inc/.env" ]'
"$arbore" create all-inc </dev/null >/dev/null 2>&1
check ".worktreeinclude が無く既定なら gitignore 全件をコピー" '[ -f "$tmp/proj.all-inc/.env" ] && [ ! -e "$tmp/proj.all-inc/README" ]'
mv .wi .worktreeinclude

echo "remove"
echo x >> "$wt/docker-compose.yaml"
check "未コミットの変更があれば止まる" '! "$arbore" remove feature/x >/dev/null 2>&1 && [ -d "$wt" ] && [ ! -e "$tmp/down.log" ]'
git -C "$wt" checkout -q docker-compose.yaml
up proj-feature-x "$wt"
check "消える（slug 指定でも実際のブランチ名を案内する）" '"$arbore" remove feature-x | grep -q "ブランチ feature/x は" && [ ! -e "$wt" ]'
check "worktree で起動したプロジェクトを down する" 'grep -qx proj-feature-x "$tmp/down.log"'
up shared "$tmp/proj.y" && up shared "$tmp/proj"
check "ブランチは残る" 'git rev-parse -q --verify refs/heads/feature/x >/dev/null'
check "外から消すと案内は出ない" '! "$arbore" remove y 2>&1 >/dev/null | grep -q "cd "'
check "本体と同じプロジェクト名なら down しない" '! grep -qx shared "$tmp/down.log"'
"$arbore" create w >/dev/null 2>&1
check "中から消すと本体への cd を案内する" '(cd "$tmp/proj.w/" && "$arbore" remove w 2>&1 >/dev/null) | grep -qF "cd $tmp/proj "'
"$arbore" create z >/dev/null 2>&1
check "空いた番号を再利用する" 'grep -q "index: 1" "$tmp/proj.z/docker-compose.override.yaml"'
check "残したブランチでもう一度 create できる" '"$arbore" create feature/x >/dev/null 2>&1 && [ "$(git -C "$wt" branch --show-current)" = feature/x ]'
git worktree add -q --detach "$tmp/proj.det"
up projdet "$tmp/proj.det"
check "detached HEAD ならブランチの案内は出さない" '! "$arbore" remove det | grep -q ブランチ'
check "override が無くても worktree で起動したものは down する" 'grep -qx projdet "$tmp/down.log"'
git worktree add -q .claude/worktrees/cc -b cc
check "list は本体の下の worktree を拾わない" '! "$arbore" list | grep -q claude'

echo "prune"
ci() { echo "$2" > "$tmp/proj.$1/$2" && git -C "$tmp/proj.$1" add "$2" && git -C "$tmp/proj.$1" commit -qm "$2"; }
"$arbore" create p-merged >/dev/null 2>&1 && ci p-merged a && git merge -q --ff-only p-merged
"$arbore" create p-squash >/dev/null 2>&1 && ci p-squash b && ci p-squash c
git merge -q --squash p-squash >/dev/null && git commit -qm squash
"$arbore" create p-rebase >/dev/null 2>&1 && ci p-rebase d && ci p-rebase e
echo f > f && git add f && git commit -qm f && git cherry-pick ..p-rebase >/dev/null
"$arbore" create p-open >/dev/null 2>&1 && ci p-open g
"$arbore" create p-fresh >/dev/null 2>&1
up gone "$tmp/proj.gone" && up outside "$tmp/elsewhere" && up live "$tmp/proj.p-open"
out="$("$arbore" prune </dev/null 2>/dev/null)"
check "消えた worktree のコンテナを拾う" 'echo "$out" | grep -qx "  $tmp/proj.gone"'
check "ほかの場所・現存する worktree のコンテナは拾わない" '! echo "$out" | grep -qE "elsewhere|proj.p-open$"'
check "ff / squash / rebase で取り込まれたものを拾う" 'echo "$out" | grep -qx "  p-merged" && echo "$out" | grep -qx "  p-squash" && echo "$out" | grep -qx "  p-rebase"'
check "未マージ・作りたて・既存の worktree は拾わない" '! echo "$out" | grep -qE "p-open|p-fresh|feature-x|  z$"'
check "確認で既定なら消さない" '[ -d "$tmp/proj.p-merged" ]'
echo y | "$arbore" prune --branch >/dev/null 2>&1
check "y で消える" '[ ! -e "$tmp/proj.p-merged" ] && [ ! -e "$tmp/proj.p-squash" ] && [ ! -e "$tmp/proj.p-rebase" ] && [ -d "$tmp/proj.p-open" ] && [ -d "$tmp/proj.p-fresh" ]'
check "y で残ったコンテナも片付ける" 'grep -qx gone "$tmp/down.log" && ! grep -qxE "outside|live" "$tmp/down.log"'
check "--branch でブランチも消える" '! git rev-parse -q --verify refs/heads/p-squash >/dev/null && git rev-parse -q --verify refs/heads/p-open >/dev/null'

echo "補完スクリプトが両シェルで読める"
check "bash" 'bash -c "eval \"\$($arbore completion)\" && complete -p arboré >/dev/null"'
if command -v zsh >/dev/null; then
  check "zsh" 'zsh -c "autoload -U compinit; compinit -u -d $tmp/zcd >/dev/null 2>&1; eval \"\$($arbore completion)\"; [[ \$(whence -w _arbore) == *function ]]"'
else
  echo "  skip: zsh がないので省略"
fi

exit $fail
