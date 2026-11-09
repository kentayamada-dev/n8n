# 既存リソースを Terraform 管理下に取り込むための import ブロック
# Public IP はエフェメラルなのでインスタンス側で管理する（ここでは import しない）
# ブートボリュームもインスタンスの一部として扱われるので import しない

import {
  to = oci_core_instance.n8n
  id = "ocid1.instance.oc1.ca-toronto-1.an2g6ljrhyiqtjacakwbtookeha63ggppahubytpyn3475nhkm22uik2ddta"
}

import {
  to = oci_core_vcn.main
  id = "ocid1.vcn.oc1.ca-toronto-1.amaaaaaahyiqtjaa4jvodgzahm5eufsj5b3x74bgge3oboruijgofe2uon4a"
}

import {
  to = oci_core_subnet.public
  id = "ocid1.subnet.oc1.ca-toronto-1.aaaaaaaalya4d65fvdie7p5nswmjcsfuv7id7v7kxq5eez4dj6hy2mzga7xq"
}

import {
  to = oci_core_internet_gateway.main
  id = "ocid1.internetgateway.oc1.ca-toronto-1.aaaaaaaacuoduuumrnkmwqfw3ysk4cdhp7grpbygv2t6jz4m6rtxl7njts7a"
}

# VCN のデフォルト・ルート表（Default Route Table for vcn）
import {
  to = oci_core_route_table.default
  id = "ocid1.routetable.oc1.ca-toronto-1.aaaaaaaaxzzupsnakvxlju6xbwzxkdyhg3cjjdbgmdt75wu5qc5xyhzhtwnq"
}

# VCN のデフォルト・セキュリティ・リスト（Default Security List for vcn）
import {
  to = oci_core_security_list.default
  id = "ocid1.securitylist.oc1.ca-toronto-1.aaaaaaaat6zd53zxekyf2xedxads47pazmsn5s33nzol4okbsy5sjmwkfrxa"
}
