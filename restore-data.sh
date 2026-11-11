#!/usr/bin/env bash
# backup-data.sh で保存したバックアップを、作り直したサーバーに戻す（サーバーの ~/n8n で ./restore-data.sh と実行する）
#
# create-env.sh と import-workflows.sh の代わりに使う（.env、ワークフロー、認証情報などがすべて戻る）
# 認証情報は暗号化キー（config）と一緒に戻すので、作り直す前と同じように使える
# ワークフローの有効・無効、オーナーのアカウント、n8n の API キー、実行履歴も元のまま戻る
#
# n8n を起動する前に実行する（起動したあとでも戻せるが、そのとき n8n が作ったデータはすべて消して置き換える）
# 新しいデータベースのファイルが一部でも残ると、戻したデータベースと混ざって壊れるおそれがあるので、残さず消す
#
# 何かを変える前に、取り出し・復号・中身と版の確認をすべて済ませ、最後に確認（y/N）してから戻す
# そのため、今のサーバーで実行して最後に N と答えれば、バックアップを戻せるかだけを試せる
#
# トンネルを作り直したときはトークンが変わるので、途中で新しい CF_TUNNEL_TOKEN を入力する
# （Mac で terraform output -raw cloudflare_tunnel_token。変わっていなければ空のまま Enter で、バックアップの値を使う）
#
# n8n の版は、バックアップを取ったときと docker-compose.yml とで同じでないと止める
# 古い版で開くとデータベースの形が合わないおそれがある。新しい版に上げるのは、戻して動くのを確かめてから別にやる
#
# 画面に出す文字は英語（ASCII）にする
# シリアル・コンソールは出力のバイトを取りこぼすことがあり、日本語（UTF-8 で 1 文字 3 バイト）は化けやすいため
set -euo pipefail

# docker-compose.yml がある場所で実行し、.env もここに作る
cd "$(dirname "$0")"

for cmd in docker gpg curl; do
  if ! command -v "$cmd" >/dev/null; then
    echo "$cmd not found. If the server was just created, wait for: cloud-init status --wait" >&2
    exit 1
  fi
done

# ubuntu ユーザーは docker グループに入っていないので、docker を直接使えなければ sudo を付ける
# docker compose は標準入力を読んでしまい、下の確認（y/N）への入力を横取りするので、/dev/null をつなぐ
if docker info >/dev/null 2>&1; then
  docker_() { docker "$@" </dev/null; }
else
  docker_() { sudo docker "$@" </dev/null; }
fi

# 入力した値を、指定した名前の変数に入れる
# 秘密の値なので -s で表示しない。貼り付けで紛れ込む CR は取り除く
ask_secret() {
  local value
  read -rsp "$2: " value
  echo
  value="${value//$'\r'/}"
  printf -v "$1" '%s' "$value"
}

# PAR の URL（backup-data.sh で使ったものと同じ）
# 貼り付けで欠けていないか確かめられるよう、値は出さずに長さとオブジェクト名だけ表示する
ask_secret par_url 'PAR URL (hidden)'
par_url_pattern='^https://[^/]+/p/[^/]+/n/[^/]+/b/[^/]+/o/([^/]+)$'
if [[ "$par_url" =~ $par_url_pattern ]]; then
  echo "  length ${#par_url}, object ${BASH_REMATCH[1]}"
else
  echo 'That is not a PAR URL for one object (https://.../p/.../n/.../b/.../o/<object>).' >&2
  exit 1
fi
ask_secret passphrase 'Passphrase of the backup (hidden)'

# 作業用のディレクトリ（自分だけが読み書きできる）。途中で止まっても中止しても、最後に必ず消す
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo 'Downloading...'
curl --fail --silent --show-error --retry 3 --output "$tmp/n8n-backup.gpg" "$par_url"

# パスフレーズはコマンドの引数に書かず（ps で見えるため）、ファイル記述子 3 番から渡す
# --no-symkey-cache: gpg-agent にパスフレーズを覚えさせない
echo 'Decrypting...'
if ! gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 --no-symkey-cache \
  --decrypt --output "$tmp/n8n-backup.tar.gz" "$tmp/n8n-backup.gpg" 3< <(printf '%s' "$passphrase"); then
  echo 'Could not decrypt the backup. Check the passphrase.' >&2
  exit 1
fi
unset passphrase

mkdir "$tmp/backup"
tar -C "$tmp/backup" -xzf "$tmp/n8n-backup.tar.gz"
for f in n8n-data.tar env n8n-image; do
  if [[ ! -f "$tmp/backup/$f" ]]; then
    echo "$f is missing in the backup." >&2
    exit 1
  fi
done
# 暗号化キー（config）がないと、戻しても認証情報を復号できない
tar -tf "$tmp/backup/n8n-data.tar" > "$tmp/data-files"
if ! grep -qx './config' "$tmp/data-files"; then
  echo 'The backup has no n8n config (the encryption key).' >&2
  exit 1
fi

# docker-compose.yml の n8n のイメージと、バックアップを取ったときのイメージを比べる
# .env はまだないことがあるので、docker-compose.yml の値はバックアップの env で埋める
backup_image=$(< "$tmp/backup/n8n-image")
current_image=$(docker_ compose --env-file "$tmp/backup/env" config --images |
  awk -v repo="${backup_image%:*}:" 'index($0, repo) == 1')
if [[ "$current_image" != "$backup_image" ]]; then
  echo "The n8n version does not match. Backup: $backup_image, docker-compose.yml: ${current_image:-(not found)}" >&2
  echo "Set the image in docker-compose.yml to $backup_image, restore, and upgrade later in a separate step." >&2
  exit 1
fi
echo "Backup is readable. n8n image: $backup_image"

echo 'If the Cloudflare tunnel was recreated, its token changed.'
echo 'Get the new one on your Mac: terraform output -raw cloudflare_tunnel_token'
ask_secret cf_tunnel_token 'New CF_TUNNEL_TOKEN (hidden, empty = keep the one in the backup)'

if [[ -e .env ]]; then
  echo 'This will overwrite .env with the one in the backup.'
fi
echo 'This will delete any n8n data on this server and replace it with the backup, then start n8n and cf.'
# 入力が終わっている（EOF）ときは「いいえ」として扱う
read -rp 'Restore now? [y/N] ' answer || answer=''
if [[ "$answer" != [yY] ]]; then
  echo 'Aborted. Nothing was changed.'
  exit 1
fi

# .env を戻す。新しいトークンを入力したときは、その行だけ入れ替える
# 自分だけが読み書きできる権限（600）で作業用ディレクトリに作ってから、置き換える
(
  umask 077
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$cf_tunnel_token" && "$line" == CF_TUNNEL_TOKEN=* ]]; then
      printf 'CF_TUNNEL_TOKEN=%s\n' "$cf_tunnel_token"
    else
      printf '%s\n' "$line"
    fi
  done < "$tmp/backup/env" > "$tmp/env.new"
)
mv "$tmp/env.new" .env
unset cf_tunnel_token

# 貼り付けで欠けていないか確かめられるよう、値は出さずに名前と長さだけ表示する（create-env.sh と同じ）
echo 'Restored .env (name and value length):'
awk '{ i = index($0, "="); printf "  %s %d\n", substr($0, 1, i - 1), length($0) - i }' .env

echo 'Restoring the n8n data...'
if docker_ inspect n8n >/dev/null 2>&1; then
  docker_ compose stop n8n
fi
# n8n のコンテナと n8n_data ボリュームを作る（起動はしない）。もうあれば、それを使う
docker_ compose create n8n
data_dir=$(docker_ inspect -f '{{range .Mounts}}{{if eq .Destination "/home/node/.n8n"}}{{.Source}}{{end}}{{end}}' n8n)
# 消す場所を間違えないよう、Docker のボリュームの場所（/var/lib/docker/volumes/<名前>/_data）であることを確かめる
if [[ "$data_dir" != /*/volumes/*/_data ]]; then
  echo "Unexpected location of the n8n data: ${data_dir:-(not found)}. Nothing was deleted." >&2
  exit 1
fi
sudo find "$data_dir" -mindepth 1 -delete
# 持ち主（UID・GID の番号）と権限も、バックアップのとおりに戻す
sudo tar -C "$data_dir" --numeric-owner -xpf "$tmp/backup/n8n-data.tar"

echo 'Starting n8n and cf...'
docker_ compose up -d

echo 'Done. n8n is starting with the restored data.'
echo 'Watch the log until n8n is ready (Ctrl+C to stop watching): sudo docker compose logs -f n8n'
echo 'Then open n8n and check that the workflows are active and the credentials work.'
echo 'After that, delete the PAR on your Mac (oci os preauth-request list / delete).'
