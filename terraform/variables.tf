variable "tenancy_ocid" {
  description = "テナンシの OCID（リソースはすべてルートコンパートメントにある）。~/.oci/config の tenancy= の値。リポジトリが公開なので、値は git 管理外の terraform.tfvars に書く"
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.tenancy\\.", var.tenancy_ocid))
    error_message = "テナンシの OCID（ocid1.tenancy. で始まる文字列）を指定してください。"
  }
}

variable "console_password_hash" {
  description = "シリアル・コンソールでログインする ubuntu ユーザーのパスワードのハッシュ（openssl passwd -6 で作る）。値は git 管理外の terraform.tfvars に書く"
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^\\$6\\$", var.console_password_hash))
    error_message = "SHA-512 のハッシュ（$6$ で始まる文字列）を指定してください。平文のパスワードは書かないでください。"
  }
}

# ---------------------------------------------------------------------------
# Cloudflare（cloudflare.tf で使う）
# どれも秘密ではないが、アカウントやドメインを特定できるので git 管理外の terraform.tfvars に書く
# API トークンは変数ではなく環境変数 CLOUDFLARE_API_TOKEN で渡す
# ---------------------------------------------------------------------------

variable "cloudflare_account_id" {
  description = "Cloudflare のアカウント ID。ダッシュボードのドメインの概要ページ右下にある「アカウント ID」"
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_account_id))
    error_message = "アカウント ID（32 文字の 16 進数）を指定してください。"
  }
}

variable "cloudflare_zone_id" {
  description = "n8n のホスト名があるドメイン（ゾーン）の ID。ダッシュボードのドメインの概要ページ右下にある「ゾーン ID」"
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
    error_message = "ゾーン ID（32 文字の 16 進数）を指定してください。"
  }
}

variable "n8n_hostname" {
  description = "n8n を公開するホスト名（例: n8n.example.com）。サーバーの .env の SUBDOMAIN.DOMAIN_NAME と同じにする"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+(\\.[a-z0-9-]+)+$", var.n8n_hostname))
    error_message = "https:// や末尾の / を付けず、ホスト名だけ（例: n8n.example.com）を指定してください。"
  }
}

variable "access_allowed_emails" {
  description = "Access で n8n に入れるメールアドレスの一覧"
  type        = list(string)

  validation {
    condition     = length(var.access_allowed_emails) > 0 && alltrue([for e in var.access_allowed_emails : can(regex("^[^@\\s]+@[^@\\s]+$", e))])
    error_message = "メールアドレスを 1 つ以上指定してください。"
  }
}
