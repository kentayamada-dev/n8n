locals {
  # リソースはすべてルートコンパートメント（テナンシ）にある
  compartment_id = var.tenancy_ocid

  # サブネットの CIDR（サブネットとセキュリティ・リストの両方で使う）
  subnet_cidr = "10.0.0.0/24"

  # すべての OCI リソースに付けるタグ。コンソールで n8n 用のリソースを絞り込むのに使う
  # 名前（display_name）は書かず OCI の既定に任せ、どのリソースかはこのタグで見分ける
  tags = {
    app = "n8n"
  }
}
