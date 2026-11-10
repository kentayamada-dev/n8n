#!/usr/bin/env bash
# docker-compose.yml が読む .env を作る（サーバーの ~/n8n で ./create-env.sh と実行する）
#
# 秘密の値（Binance の API キー、トンネルのトークン）は画面に表示せずに読み込む
# シリアル・コンソールの出力はコンソール履歴として保存できるので、エディタで開いて表示しないため
# 値はシェルの履歴にも残らない
#
# サブドメインとドメインは秘密ではないので表示して入力する
# （リポジトリが公開なので、ドメインはこのファイルに書かない）
#
# 画面に出す文字は英語（ASCII）にする
# シリアル・コンソールは出力のバイトを取りこぼすことがあり、日本語（UTF-8 で 1 文字 3 バイト）は化けやすいため
set -euo pipefail

# .env は docker-compose.yml と同じディレクトリに作る
cd "$(dirname "$0")"

if [[ -e .env ]]; then
  read -rp '.env already exists. Overwrite? [y/N] ' answer
  if [[ "$answer" != [yY] ]]; then
    echo 'Aborted. .env was not changed.'
    exit 1
  fi
fi

# 入力した値を、指定した名前の変数に入れる
# 秘密の値は -s で表示しない。貼り付けで紛れ込む CR は取り除き、空なら止める
ask() {
  local name="$1" label="$2" hint="$3" secret="$4" value
  if [[ "$secret" == secret ]]; then
    read -rsp "$label$hint: " value
    echo
  else
    read -rp "$label$hint: " value
  fi
  value="${value//$'\r'/}"
  if [[ -z "$value" ]]; then
    echo "$label is empty. Run the script again. .env was not changed." >&2
    exit 1
  fi
  printf -v "$name" '%s' "$value"
}

ask binance_api_key BINANCE_API_KEY '' secret
ask binance_api_secret BINANCE_API_SECRET '' secret
ask cf_tunnel_token CF_TUNNEL_TOKEN '' secret
ask subdomain SUBDOMAIN ' (e.g. n8n)' plain
ask domain_name DOMAIN_NAME ' (e.g. example.com)' plain

# 自分だけが読み書きできる権限（600）で作る
(
  umask 077
  printf '%s=%s\n' \
    BINANCE_API_KEY "$binance_api_key" \
    BINANCE_API_SECRET "$binance_api_secret" \
    SUBDOMAIN "$subdomain" \
    DOMAIN_NAME "$domain_name" \
    CF_TUNNEL_TOKEN "$cf_tunnel_token" \
    > .env
)
unset binance_api_key binance_api_secret cf_tunnel_token

# 貼り付けで欠けていないか確かめられるよう、値は出さずに名前と長さだけ表示する
# （値に = が入っていても正しく数えるよう、最初の = で分ける）
echo 'Created .env (name and value length):'
awk '{ i = index($0, "="); printf "  %s %d\n", substr($0, 1, i - 1), length($0) - i }' .env
echo 'Compare the CF_TUNNEL_TOKEN length with this on your Mac:'
echo '  terraform output -raw cloudflare_tunnel_token | wc -c'
