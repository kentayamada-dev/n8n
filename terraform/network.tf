# defined_tags（Oracle-Tags.CreatedBy / CreatedOn）は OCI が自動で付けるタグなので、
# コードには書かずに ignore_changes で差分を無視する（作成者のメールアドレスも含まれるため）

resource "oci_core_vcn" "main" {
  compartment_id          = local.compartment_id
  cidr_block              = "10.0.0.0/16"
  cidr_blocks             = ["10.0.0.0/16"]
  display_name            = "vcn"
  dns_label               = "vcn"
  freeform_tags           = {}
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
  display_name   = "Internet Gateway"
  enabled        = true
  freeform_tags  = {}

  lifecycle {
    ignore_changes = [defined_tags]
  }
}

# VCN 作成時に自動で作られたデフォルトのルート表
resource "oci_core_route_table" "default" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "Default Route Table for vcn"
  freeform_tags  = {}

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

# VCN 作成時に自動で作られたデフォルトのセキュリティ・リスト
resource "oci_core_security_list" "default" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "Default Security List for vcn"
  freeform_tags  = {}

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

  # SSH: 自宅の IP からだけ許可する（値は terraform.tfvars で指定）
  ingress_security_rules {
    protocol    = "6"
    source      = var.ssh_allowed_cidr
    source_type = "CIDR_BLOCK"
    stateless   = false

    tcp_options {
      min = 22
      max = 22
    }
  }

  lifecycle {
    ignore_changes = [defined_tags]
  }
}

resource "oci_core_subnet" "public" {
  compartment_id             = local.compartment_id
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = "10.0.0.0/24"
  ipv4cidr_blocks            = ["10.0.0.0/24"]
  ipv6cidr_blocks            = []
  display_name               = "subnet"
  dns_label                  = "subnet"
  freeform_tags              = {}
  dhcp_options_id            = oci_core_vcn.main.default_dhcp_options_id
  route_table_id             = oci_core_route_table.default.id
  security_list_ids          = [oci_core_security_list.default.id]
  prohibit_internet_ingress  = false
  prohibit_public_ip_on_vnic = false

  lifecycle {
    ignore_changes = [defined_tags]
  }
}
