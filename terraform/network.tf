# defined_tags（Oracle-Tags.CreatedBy / CreatedOn）は OCI が自動で付けるタグなので、
# コードには書かずに ignore_changes で差分を無視する（作成者のメールアドレスも含まれるため）

resource "oci_core_vcn" "main" {
  compartment_id = local.compartment_id
  # cidr_block は非推奨で、cidr_blocks と両方書くと作成時にエラーになるので cidr_blocks だけ書く
  cidr_blocks             = ["10.0.0.0/16"]
  dns_label               = "vcn"
  freeform_tags           = local.tags
  ipv6private_cidr_blocks = []
  is_ipv6enabled          = false
  security_attributes     = {}

  lifecycle {
    ignore_changes = [defined_tags]
  }
}

resource "oci_core_internet_gateway" "main" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.main.id
  enabled        = true
  freeform_tags  = local.tags

  lifecycle {
    ignore_changes = [defined_tags]
  }
}

# VCN を作ると自動でできるデフォルトのルート表とセキュリティ・リストは、単体では削除できない
# そのため oci_core_default_* で「中身（ルール）だけ」を管理する（VCN を削除すると一緒に消える）
# 参考: https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/terraformbestpractices_topic-vcndefaults.htm

# デフォルトのルート表
resource "oci_core_default_route_table" "default" {
  manage_default_resource_id = oci_core_vcn.main.default_route_table_id
  freeform_tags              = local.tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
    route_type        = "STATIC"
  }

  lifecycle {
    ignore_changes = [defined_tags]
  }
}

# デフォルトのセキュリティ・リスト
# VCN を新しく作ると SSH（22番）を全開放するルールが入っているが、ここに書いたルールで置き換えるので消える
resource "oci_core_default_security_list" "default" {
  manage_default_resource_id = oci_core_vcn.main.default_security_list_id
  freeform_tags              = local.tags

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
    stateless        = false
  }

  # ICMP type 3（到達不能）: VCN 内から
  ingress_security_rules {
    protocol    = "1"
    source      = "10.0.0.0/16"
    source_type = "CIDR_BLOCK"
    stateless   = false

    icmp_options {
      type = 3
      code = -1
    }
  }

  # ICMP type 3 code 4（Path MTU Discovery 用）: どこからでも
  ingress_security_rules {
    protocol    = "1"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    stateless   = false

    icmp_options {
      type = 3
      code = 4
    }
  }

  # SSH は開けない。インスタンスへの接続は OCI コンソールのシリアル・コンソール接続だけで行う
  # （n8n は Cloudflare Tunnel 経由の外向き接続で公開しているので、受信ポートは不要）

  lifecycle {
    ignore_changes = [defined_tags]
  }
}

resource "oci_core_subnet" "public" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.main.id
  # ipv4cidr_blocks・prohibit_internet_ingress は cidr_block・prohibit_public_ip_on_vnic と同じ意味の別名
  # 作成時に両方渡すとエラーになるおそれがあるので、片方だけ書く
  cidr_block                 = local.subnet_cidr
  ipv6cidr_blocks            = []
  dns_label                  = "subnet"
  freeform_tags              = local.tags
  dhcp_options_id            = oci_core_vcn.main.default_dhcp_options_id
  route_table_id             = oci_core_default_route_table.default.id
  security_list_ids          = [oci_core_default_security_list.default.id]
  prohibit_public_ip_on_vnic = false # パブリック・サブネット（インスタンスに Public IP を付けて外へ出る）

  lifecycle {
    ignore_changes = [defined_tags]
  }
}
