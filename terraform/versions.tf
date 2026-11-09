terraform {
  # backend "oci" は Terraform 1.12 で追加された
  required_version = ">= 1.12"

  # state は OCI Object Storage のバケットに置く
  # バケットはバージョニング有効・非公開で、Terraform の管理外（OCI CLI で作成）
  # namespace はテナンシを特定できる値なので、git 管理外の backend.tfbackend に書き、
  #   terraform init -backend-config=backend.tfbackend
  # で渡す（backend.tfbackend.example を参照）
  backend "oci" {
    bucket              = "terraform-state"
    key                 = "n8n/terraform.tfstate"
    region              = "ca-toronto-1"
    auth                = "APIKey"
    config_file_profile = "DEFAULT"
  }

  required_providers {
    oci = {
      source = "oracle/oci"
      # メジャーバージョンが勝手に上がらないよう 9.x に限定する
      # 実際に使うバージョンは .terraform.lock.hcl で固定している
      version = "~> 9.12"
    }
  }
}

provider "oci" {
  config_file_profile = "DEFAULT"
  region              = "ca-toronto-1"
}
