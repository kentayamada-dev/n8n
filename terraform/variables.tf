variable "console_password_hash" {
  description = "シリアル・コンソールでログインする ubuntu ユーザーのパスワードのハッシュ（openssl passwd -6 で作る）。値は git 管理外の terraform.tfvars に書く"
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^\\$6\\$", var.console_password_hash))
    error_message = "SHA-512 のハッシュ（$6$ で始まる文字列）を指定してください。平文のパスワードは書かないでください。"
  }
}
