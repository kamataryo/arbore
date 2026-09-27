# Arboré

`git worktree` の糖衣コマンドです。worktree を作るときに、`.worktreeinclude` のファイルのコピーと、Docker Compose がぶつからないための override の生成を自動で行います。

## 必要なもの

- Git 2.31 以降
- jq（Docker Compose を使うプロジェクトのみ）
- Docker Compose v2.24 以降（`!override` を使うため。Compose を使うプロジェクトのみ）

## インストール

```shell
git clone https://github.com/kamataryo/arbore.git
```

以下を `.zshrc`（bash なら `.bashrc`）に追記します。`/path/to/arbore` は `git clone` したパスに読み替えてください。

```shell
export PATH="/path/to/arbore/bin:$PATH"
eval "$(arboré completion)" # 補完。bash / zsh 両対応
```

## 使い方

```shell
cd <リポジトリ>
arboré create feature/login   # ../<repo>.feature-login に worktree を作る
arboré remove feature/login   # 片付ける（ブランチは残る）
```

| コマンド | 動作 |
|---|---|
| `arboré create <name>` | 現在の HEAD からブランチ `<name>` を作り、`../<repo>.<name>` に worktree を置きます。`/` はディレクトリ名では `-` になります |
| `arboré remove <name>` | コンテナとボリュームを `docker compose down --volumes` で消してから、worktree を削除します。ブランチは残します |
| `arboré dir <name>` | worktree のパスを出力します。`cd "$(arboré dir <name>)"` で移動できます |
| `arboré list` | arboré で作った worktree の名前を一覧します |
| `arboré help` | ヘルプを表示します |
| `arboré completion` | 補完スクリプトを出力します |

worktree の中から実行しても、本体のリポジトリを基準に動きます。

### `.worktreeinclude`

本体のルートに `.worktreeinclude` を置くと、そのパターン（`.gitignore` と同じ書式）に一致し、**かつ gitignore されている**ファイルを新しい worktree へコピーします。`.env` など、Git 管理外だけど動かすのに必要なファイル向けです。

```
.env
.env.local
```

`node_modules` なども書けばコピーされますが、大きいと時間がかかります。

`.worktreeinclude` が無いときは `[Y/n]` で確認し、Y（既定）なら gitignore されたファイルをすべてコピーします。

### Docker Compose の override

compose ファイル（`compose.yaml` / `docker-compose.yaml` など）があると、`docker compose config` で正規化した構成から `docker-compose.override.yaml` を生成します。Compose が自動で読む名前なので、worktree の中では `docker compose up` するだけで効きます。

- プロジェクト名を `<repo>-<name>` にします（元の compose が `name:` を固定していても本体と分かれます）
- `container_name` の先頭に `<repo>-<name>-` を付けます
- 公開ポートを `+1000 × 番号` ずらします。番号は空いている一番小さいものを worktree ごとに割り当てます（1 つ目は +1000、2 つ目は +2000）

次の場合は override を生成しません。

- すでに override ファイルがある（Git 管理下、または `.worktreeinclude` でコピーされた）
- docker コマンドが無い

`name:` を明示した network / volume は本体と共有されてしまうので、警告だけ出します。

### 削除時の安全弁

未コミットの変更（生成した override 以外）が worktree にあると、`remove` は何もせずに止まります。承知の上で消すときは `git worktree remove --force` を直接使ってください。
