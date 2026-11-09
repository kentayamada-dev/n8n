terraform {
  required_version = ">= 1.5"

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
