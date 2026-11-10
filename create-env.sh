#!/usr/bin/env bash
# docker-compose.yml が読む .env を作る（サーバーの ~/n8n で ./create-env.sh と実行する）
#
# 秘密の値（Binance の API キー、トンネルのトークン）は画面に表示せずに読み込む
# シリアル・コンソールの出力はコンソール履歴として保存できるので、エディタで開いて表示しないため
# 値はシェルの履歴にも残らない
#
# サブドメインとドメインは秘密ではないので表示して入力する
# （リポジトリが公開なので、ドメインはこのファイルに書かない）
set -euo pipefail

# .env は docker-compose.yml と同じディレクトリに作る
cd "$(dirname "$0")"

if [[ -e .env ]]; then
  read -rp '.env はすでにあります。上書きしますか？ [y/N] ' answer
  if [[ "$answer" != [yY] ]]; then
    echo '中止しました。.env は変更していません。'
    exit 1
  fi
fi

# 入力した値を、指定した名前の変数に入れる
# 秘密の値は -s で表示しない。貼り付けで紛れ込む CR は取り除き、空なら止める
ask() {
  local name="$1" prompt="$2" secret="$3" value
  if [[ "$secret" == secret ]]; then
    read -rsp "$prompt: " value
    echo
  else
    read -rp "$prompt: " value
  fi
  value="${value//$'\r'/}"
  if [[ -z "$value" ]]; then
    echo "$prompt が空です。もう一度実行してください。.env は変更していません。" >&2
    exit 1
  fi
  printf -v "$name" '%s' "$value"
}

ask binance_api_key 'BINANCE_API_KEY' secret
ask binance_api_secret 'BINANCE_API_SECRET' secret
ask cf_tunnel_token 'CF_TUNNEL_TOKEN（Mac で terraform output -raw cloudflare_tunnel_token）' secret
ask subdomain 'SUBDOMAIN（例: n8n）' plain
ask domain_name 'DOMAIN_NAME（例: example.com）' plain

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
echo '.env を作りました（名前と値の長さ）:'
awk '{ i = index($0, "="); printf "  %s %d\n", substr($0, 1, i - 1), length($0) - i }' .env
echo 'CF_TUNNEL_TOKEN の長さは、Mac の terraform output -raw cloudflare_tunnel_token | wc -c と比べてください。'
