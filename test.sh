#!/bin/sh
# arboré の create / remove を一時リポジトリで検証する。Docker は不要（docker を差し替える）。
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
arbore="$here/bin/arboré"
tmp="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/arbore-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fail=0
check() { if eval "$2"; then echo "  ok: $1"; else echo "  NG: $1"; fail=1; fi; }

# docker compose config は正規化済みの JSON を返すだけにして、down は呼ばれたことを記録する
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<EOF
#!/bin/sh
case "\$2" in
  config) cat <<'JSON'
{"name":"fixed","services":{
  "web":{"container_name":"proxy","ports":[
    {"target":80,"published":"8080"},
    {"host_ip":"127.0.0.1","target":81,"published":"18080-18081"},
    {"target":9000}]},
  "worker":{"image":"busybox"}}}
JSON
  ;;
  down) echo down >> "$tmp/down.log" ;;
esac
EOF
chmod +x "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

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
check "消える（slug 指定でも実際のブランチ名を案内する）" '"$arbore" remove feature-x | grep -q "ブランチ feature/x は" && [ ! -e "$wt" ]'
check "compose down を呼ぶ" '[ -f "$tmp/down.log" ]'
check "ブランチは残る" 'git rev-parse -q --verify refs/heads/feature/x >/dev/null'
check "外から消すと案内は出ない" '! "$arbore" remove y 2>&1 >/dev/null | grep -q "cd "'
"$arbore" create w >/dev/null 2>&1
check "中から消すと本体への cd を案内する" '(cd "$tmp/proj.w/" && "$arbore" remove w 2>&1 >/dev/null) | grep -qF "cd $tmp/proj "'
"$arbore" create z >/dev/null 2>&1
check "空いた番号を再利用する" 'grep -q "index: 1" "$tmp/proj.z/docker-compose.override.yaml"'
check "残したブランチでもう一度 create できる" '"$arbore" create feature/x >/dev/null 2>&1 && [ "$(git -C "$wt" branch --show-current)" = feature/x ]'
git worktree add -q --detach "$tmp/proj.det"
check "detached HEAD ならブランチの案内は出さない" '! "$arbore" remove det | grep -q ブランチ'
git worktree add -q .claude/worktrees/cc -b cc
check "list は本体の下の worktree を拾わない" '! "$arbore" list | grep -q claude'

echo "補完スクリプトが両シェルで読める"
check "bash" 'bash -c "eval \"\$($arbore completion)\" && complete -p arboré >/dev/null"'
if command -v zsh >/dev/null; then
  check "zsh" 'zsh -c "autoload -U compinit; compinit -u -d $tmp/zcd >/dev/null 2>&1; eval \"\$($arbore completion)\"; [[ \$(whence -w _arbore) == *function ]]"'
else
  echo "  skip: zsh がないので省略"
fi

exit $fail
