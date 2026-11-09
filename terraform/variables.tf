variable "ssh_allowed_cidr" {
  description = "SSH を許可する接続元（自宅のグローバル IP/32）。値は git 管理外の terraform.tfvars に書く"
  type        = string
}
