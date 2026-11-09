terraform {
  required_version = ">= 1.5"

  # state は OCI Object Storage のバケットに置く
  # バケットはバージョニング有効・非公開で、Terraform の管理外（OCI CLI で作成）
  backend "oci" {
    bucket              = "terraform-state"
    namespace           = "yzjyztqzdyi7"
    key                 = "n8n/terraform.tfstate"
    region              = "ca-toronto-1"
    auth                = "APIKey"
    config_file_profile = "DEFAULT"
  }

  required_providers {
    oci = {
      source = "oracle/oci"
      # バージョンは terraform init で生成される .terraform.lock.hcl で固定する
    }
  }
}

provider "oci" {
  config_file_profile = "DEFAULT"
  region              = "ca-toronto-1"
}
