locals {
  # リソースはすべてルートコンパートメント（テナンシ）にある
  compartment_id = "ocid1.tenancy.oc1..aaaaaaaaodionbvq2x2b53e74rl2l223jwb4vx6thp32hyojf74rakzckpja"

  # サブネットの CIDR（サブネットとセキュリティ・リストの両方で使う）
  subnet_cidr = "10.0.0.0/24"
}
