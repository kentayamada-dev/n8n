locals {
  # リソースはすべてルートコンパートメント（テナンシ）にある
  compartment_id = var.tenancy_ocid

  # サブネットの CIDR（サブネットとセキュリティ・リストの両方で使う）
  subnet_cidr = "10.0.0.0/24"
}
