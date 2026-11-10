# n8n を Cloudflare Tunnel で公開するための設定（トンネル・転送先・DNS・Access）

# トンネル本体
# 転送先などの設定は Cloudflare 側に置き（config_src = "cloudflare"）、サーバーの cloudflared はトークンだけで動かす
# トンネルを作り直すとトークンが変わるので、サーバーの .env の CF_TUNNEL_TOKEN も入れ替える
resource "cloudflare_zero_trust_tunnel_cloudflared" "n8n" {
  account_id = var.cloudflare_account_id
  name       = "n8n"
  config_src = "cloudflare"
}

# cloudflared の起動に使うトークン（サーバーの .env の CF_TUNNEL_TOKEN に入れる値）
# 取り出し方: terraform output -raw cloudflare_tunnel_token
data "cloudflare_zero_trust_tunnel_cloudflared_token" "n8n" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.n8n.id
}

output "cloudflare_tunnel_token" {
  description = "サーバーの .env の CF_TUNNEL_TOKEN に入れる値"
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.n8n.token
  sensitive   = true
}

# トンネルの転送先
# cf コンテナと n8n コンテナは同じ Docker のネットワークにいるので、コンテナ名で n8n に届く
# （docker-compose.yml でホストにポートを開けていないため、localhost やホストの IP では届かない）
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "n8n" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.n8n.id

  config = {
    ingress = [
      {
        hostname = var.n8n_hostname
        service  = "http://n8n:5678"
      },
      # 最後のルールはどのホスト名にも当てはまらなかったときの受け皿（cloudflared が必須にしている）
      {
        service = "http_status:404"
      },
    ]
  }
}

# n8n のホスト名をトンネルに向ける
# ダッシュボードで公開ホスト名を作ると自動でできるレコードだが、API で転送先を設定した場合は自動ではできない
resource "cloudflare_dns_record" "n8n" {
  zone_id = var.cloudflare_zone_id
  name    = var.n8n_hostname
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.n8n.id}.cfargotunnel.com"
  proxied = true # トンネルへの CNAME は proxied でないと届かない
  ttl     = 1    # 1 は自動（proxied のときは自動しか選べない）

  # Access で塞いでからホスト名を公開する
  # （DNS が先にできると、Access ができるまでの間、n8n のログインだけで外から入れてしまう）
  depends_on = [cloudflare_zero_trust_access_application.n8n]
}

# ---------------------------------------------------------------------------
# Access（n8n の画面に入る前に Cloudflare でログインさせる）
# n8n のログインだけに頼らず、許可したメールアドレスの人しか n8n に届かないようにする
# ログイン方法は Zero Trust の「認証」の設定に従う（今は Cloudflare アカウントでのログインだけ）
# ---------------------------------------------------------------------------

locals {
  # Access を通さずに受け付ける Webhook のパス。ここに書いたものだけ認証なしで通し、それ以外の /webhook/... は Access が必要
  # 外部サービス（Slack など）は Cloudflare にログインできないため。パスは「/webhook/<ノードの webhookId>/webhook」
  # webhookId はワークフローの JSON（workflows/*.json）にある。ワークフローを作り直して変わったら、ここも直す
  public_webhook_paths = [
    "/webhook/a283f8b9-ae5a-48c8-93b3-1b30806e073a/webhook", # 支出記録「Slackメッセージを受け取る」（Slack トリガー）
  ]
}

# 許可したメールアドレスの人だけ通す
resource "cloudflare_zero_trust_access_policy" "n8n_owner" {
  account_id = var.cloudflare_account_id
  name       = "n8n - allow owner"
  decision   = "allow"
  include    = [for email in var.access_allowed_emails : { email = { email = email } }]
}

# 誰でも認証なしで通す（上の Webhook のパス用）
# 偽のリクエストは n8n の Slack トリガーが署名で弾く。ただし検証するのは、n8n の Slack の認証情報に
# Signature Secret（Slack アプリの Signing Secret）を入れたときだけ。空だと誰の POST でも通るので必ず入れる
resource "cloudflare_zero_trust_access_policy" "n8n_webhook_bypass" {
  account_id = var.cloudflare_account_id
  name       = "n8n - bypass webhooks"
  decision   = "bypass"
  include    = [{ everyone = {} }]
}

# public_webhook_paths のパスだけは Access を通さない
# パスを指定したアプリケーションは、ホスト名全体のアプリケーションより優先される
# テスト用の /webhook-test は通さない（Slack に登録できる URL は 1 つだけで、普段は本番の URL を使うため）
resource "cloudflare_zero_trust_access_application" "n8n_webhook" {
  account_id = var.cloudflare_account_id
  name       = "n8n webhooks"
  type       = "self_hosted"
  domain     = "${var.n8n_hostname}${local.public_webhook_paths[0]}"

  destinations = [
    for path in local.public_webhook_paths : { type = "public", uri = "${var.n8n_hostname}${path}" }
  ]

  policies = [
    { id = cloudflare_zero_trust_access_policy.n8n_webhook_bypass.id, precedence = 1 },
  ]
}

# ホスト名全体（n8n の画面・API）は許可した人だけ
resource "cloudflare_zero_trust_access_application" "n8n" {
  account_id       = var.cloudflare_account_id
  name             = "n8n"
  type             = "self_hosted"
  domain           = var.n8n_hostname
  session_duration = "24h"

  destinations = [
    { type = "public", uri = var.n8n_hostname },
  ]

  policies = [
    { id = cloudflare_zero_trust_access_policy.n8n_owner.id, precedence = 1 },
  ]

  # 先に Webhook の除外を作ってから全体を塞ぐ（逆順だと、その間 Slack からの Webhook が止まる）
  depends_on = [cloudflare_zero_trust_access_application.n8n_webhook]
}
