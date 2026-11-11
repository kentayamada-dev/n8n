#!/usr/bin/env bash
# n8n のデータと .env を暗号化して、OCI Object Storage に保存する（サーバーの ~/n8n で ./backup-data.sh と実行する）
# 戻すときは、作り直したサーバーで ./restore-data.sh を実行する
#
# インスタンスを作り直す前に取る。作り直すとブートボリュームごと消え、
# その中の n8n_data ボリューム（データベースと認証情報の暗号化キー）と .env も消えるため
# （terraform/compute.tf の preserve_boot_volume = false）
# git にあるのはワークフローの JSON だけで、認証情報はない（リポジトリが公開なので入れない）
#
# 保存するもの（1 つのファイルにまとめて暗号化する）:
#   n8n-data.tar  n8n_data ボリュームの中身（/home/node/.n8n。データベースと暗号化キーの config など）
#                 認証情報、ワークフロー、オーナーのアカウント、n8n の API キー、実行履歴がすべて入っている
#   env           .env（Binance の API キーなど）
#   n8n-image     動いていた n8n のイメージ（restore-data.sh が、戻す先と版が同じか確かめるのに使う）
#
# SSH を開けていないので、サーバーから外へ出す経路として Object Storage の事前認証済みリクエスト（PAR）を使う
# PAR は URL を知っていれば誰でも読み書きできるので、中身はパスフレーズで暗号化（gpg、AES-256）してから送る
# パスフレーズを忘れると戻せないので、パスワード・マネージャーなどに控える
#
# 事前に Mac でバケットと PAR を作っておく
# バケットは Terraform では管理しない（作り直しで一緒に消えないように）
# PAR は 1 つのオブジェクトを読み書きできるものを作り、同じ URL をバックアップと復元の両方で使う
#   oci os bucket create --compartment-id <テナンシの OCID> --name n8n-backup
#   oci os preauth-request create --bucket-name n8n-backup --name n8n-backup \
#     --access-type ObjectReadWrite --object-name n8n-backup.gpg \
#     --time-expires <期限。例: 2026-12-01T00:00:00Z> --query 'data."full-path"' --raw-output
# 出てきた URL を、このスクリプトの入力に貼り付ける（画面には表示しない）
# 戻し終わったら PAR を消す（oci os preauth-request list / delete --bucket-name n8n-backup）
#
# データベースを書きかけの状態で写さないよう、n8n をいったん止めてから写し、写し終えたらすぐ起動し直す
# 止めている間は n8n に届かない
# 起動し直したあとに n8n で変えたことはバックアップに入らないので、作り直すまで変更しない
#
# 画面に出す文字は英語（ASCII）にする
# シリアル・コンソールは出力のバイトを取りこぼすことがあり、日本語（UTF-8 で 1 文字 3 バイト）は化けやすいため
set -euo pipefail

# docker-compose.yml と .env がある場所で実行する
cd "$(dirname "$0")"

# ubuntu ユーザーは docker グループに入っていないので、docker を直接使えなければ sudo を付ける
# docker compose は標準入力を読んでしまい、下の確認（y/N）への入力を横取りするので、/dev/null をつなぐ
if docker info >/dev/null 2>&1; then
  docker_() { docker "$@" </dev/null; }
else
  docker_() { sudo docker "$@" </dev/null; }
fi

for cmd in gpg curl; do
  if ! command -v "$cmd" >/dev/null; then
    echo "$cmd not found." >&2
    exit 1
  fi
done
if [[ ! -f .env ]]; then
  echo '.env not found. Run this in ~/n8n on the server that runs n8n.' >&2
  exit 1
fi
if ! docker_ inspect n8n >/dev/null 2>&1; then
  echo 'The n8n container was not found.' >&2
  exit 1
fi

# n8n_data ボリュームの、ホスト側の場所（/var/lib/docker/volumes/<名前>/_data）
data_dir=$(docker_ inspect -f '{{range .Mounts}}{{if eq .Destination "/home/node/.n8n"}}{{.Source}}{{end}}{{end}}' n8n)
image=$(docker_ inspect -f '{{.Config.Image}}' n8n)
was_running=$(docker_ inspect -f '{{.State.Running}}' n8n)
# 暗号化キー（config）がなければ、n8n のデータの場所ではない
if [[ -z "$data_dir" ]] || ! sudo test -f "$data_dir/config"; then
  echo 'n8n data (config) was not found in the n8n_data volume.' >&2
  exit 1
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

# PAR の URL（https://<ホスト>/p/<トークン>/n/<ネームスペース>/b/<バケット>/o/<オブジェクト名>）
# 貼り付けで欠けていないか確かめられるよう、値は出さずに長さとオブジェクト名だけ表示する
ask_secret par_url 'PAR URL (hidden)'
par_url_pattern='^https://[^/]+/p/[^/]+/n/[^/]+/b/[^/]+/o/([^/]+)$'
if [[ "$par_url" =~ $par_url_pattern ]]; then
  echo "  length ${#par_url}, object ${BASH_REMATCH[1]}"
else
  echo 'That is not a PAR URL for one object (https://.../p/.../n/.../b/.../o/<object>).' >&2
  exit 1
fi

ask_secret passphrase 'Passphrase to encrypt the backup (hidden)'
ask_secret passphrase_again 'Passphrase again'
if [[ "$passphrase" != "$passphrase_again" ]]; then
  echo 'The passphrases do not match.' >&2
  exit 1
fi
unset passphrase_again
if (( ${#passphrase} < 12 )); then
  echo 'Use a passphrase of 12 characters or more.' >&2
  exit 1
fi

if [[ "$was_running" == true ]]; then
  echo "n8n ($image) will be stopped while its data is copied, then started again."
fi
# 入力が終わっている（EOF）ときは「いいえ」として扱う
read -rp 'Back up now? [y/N] ' answer || answer=''
if [[ "$answer" != [yY] ]]; then
  echo 'Aborted. Nothing was changed.'
  exit 1
fi

# 作業用のディレクトリ（自分だけが読み書きできる）。途中で止まっても、最後に必ず消す
# n8n を止めたまま終わらないよう、止めていたら起動し直す
tmp=$(mktemp -d)
n8n_stopped=false
cleanup() {
  rm -rf "$tmp"
  if [[ "$n8n_stopped" == true ]]; then
    docker_ compose start n8n >/dev/null 2>&1 || echo 'Could not start n8n. Run: sudo docker compose up -d' >&2
  fi
}
trap cleanup EXIT

if [[ "$was_running" == true ]]; then
  echo 'Stopping n8n...'
  n8n_stopped=true
  docker_ compose stop --timeout 30 n8n
fi
echo 'Copying the n8n data...'
# 持ち主は名前ではなく番号（UID・GID）で残す。コンテナの node（1000）とホストのユーザーは名前が違うため
# 権限もそのまま残る（config は n8n のユーザーだけが読める 0600）
sudo tar -C "$data_dir" --numeric-owner -cf - . > "$tmp/n8n-data.tar"
if [[ "$n8n_stopped" == true ]]; then
  echo 'Starting n8n...'
  docker_ compose start n8n
  n8n_stopped=false
fi

cp .env "$tmp/env"
printf '%s\n' "$image" > "$tmp/n8n-image"

# パスフレーズはコマンドの引数に書かず（ps で見えるため）、ファイル記述子 3 番から渡す
# --no-symkey-cache: gpg-agent にパスフレーズを覚えさせない
# --s2k-*: パスフレーズから鍵を作る計算を重くして、総当たりで当てにくくする
# 先に gzip で圧縮しているので、gpg では圧縮しない
gpg_() {
  gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 --no-symkey-cache "$@" 3< <(printf '%s' "$passphrase")
}

echo 'Encrypting...'
tar -C "$tmp" -czf - n8n-data.tar env n8n-image |
  gpg_ --symmetric --cipher-algo AES256 --s2k-digest-algo SHA512 --s2k-count 65011712 \
    --compress-algo none --output "$tmp/n8n-backup.gpg"

# 暗号化したものを、同じパスフレーズで復号でき、中身がそろっているか確かめる
contents=$(gpg_ --decrypt "$tmp/n8n-backup.gpg" | tar -tzf - | LC_ALL=C sort | tr '\n' ' ')
if [[ "$contents" != 'env n8n-data.tar n8n-image ' ]]; then
  echo 'The encrypted backup could not be read back.' >&2
  exit 1
fi

# 同じ名前のオブジェクトがあれば上書きする（残すのは最新の 1 つだけ）
echo "Uploading $(stat -c %s "$tmp/n8n-backup.gpg") bytes..."
curl --fail --silent --show-error --retry 3 --output /dev/null --upload-file "$tmp/n8n-backup.gpg" "$par_url"

# 取り出したものが、送ったものと同じか確かめる
echo 'Verifying the upload...'
local_sum=$(sha256sum < "$tmp/n8n-backup.gpg")
remote_sum=$(curl --fail --silent --show-error --retry 3 "$par_url" | sha256sum)
if [[ "$local_sum" != "$remote_sum" ]]; then
  echo 'The uploaded file does not match. Run the script again.' >&2
  exit 1
fi

echo 'Done. The backup was uploaded and verified.'
echo 'Keep the passphrase. Without it the backup cannot be restored.'
echo 'Do not change anything in n8n until the server is rebuilt (changes from now on are not in the backup).'
echo 'On the new server, run ./restore-data.sh instead of ./create-env.sh and ./import-workflows.sh.'
