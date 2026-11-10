# n8n + cloudflared を動かしているインスタンス（Always Free の A1 枠 4 OCPU / 24 GB をすべて使用）
# 作り直すと A1 の空き容量不足で同じ構成を確保し直せないおそれがあるため、destroy を禁止している
resource "oci_core_instance" "n8n" {
  compartment_id      = local.compartment_id
  availability_domain = "etSH:CA-TORONTO-1-AD-1"
  fault_domain        = "FAULT-DOMAIN-2"
  shape               = "VM.Standard.A1.Flex"
  extended_metadata   = {}
  freeform_tags       = local.tags
  security_attributes = {}

  # RUNNING を指定しているので、コンソールで停止しても次の apply で起動される
  state = "RUNNING"

  # ブートボリュームとの通信を暗号化する。作成時に効くのはこちら（launch_options の同名の値は作成後の状態）
  is_pv_encryption_in_transit_enabled = true

  # インスタンスを削除したら、ブートボリュームも一緒に削除する（Always Free の 200 GB 枠を残ったボリュームで使わないため）
  # n8n のデータもブートボリュームに入っているので、作り直すとデータは消える
  preserve_boot_volume = false

  metadata = {
    ssh_authorized_keys = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCyLBTdOgiofvADIgG4CpjpxMkTb/LMTCcGTNV6/K30NT+MIkJq5QL4fDMy3VcakblEKUhIh8lKlrqJ4H7LhYRsEqzJC0Q4aBkeOyarv0HVoB7XPa4ct5Ozy4+8pX+gbi8j/oRfkafJZWvMpR4RVckwq9C9rT/YZG+uSa8alEOZXeLRTGU6ka4KyKaOftbClCWvBl6U0K+A8Hlv/HxoeY09cg/jo8INzAWHV1g3nh1mxMcTTLb+6CzPedMxTfOdpe9cfGGuq44YJaaixnKbM8VH4Z7DWFhEOdzLq8hflxM6Lo2J3s/IMe9PP0uH87+l/HKthRO10B6YNRacsNrfu+lH ssh-key-2026-03-31"

    # 初回起動時の設定（シリアル・コンソール用パスワードなど）。作り直すときにだけ効く
    # metadata は ignore_changes なので、書き換えても今のインスタンスには反映されない（作り直したときに効く）
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
      password_hash = var.console_password_hash
    }))
  }

  # local_volume_size_in_gbs と nvmes はローカル NVMe 付きのシェイプ用（A1 にはない）
  # import したときは 0 が入っていたが、作成時に 0 を渡すと API がエラーにするので書かない
  shape_config {
    ocpus         = 4
    memory_in_gbs = 24
    vcpus         = 4
  }

  source_details {
    source_type                     = "image"
    source_id                       = "ocid1.image.oc1.ca-toronto-1.aaaaaaaa6jqvlq72cmky2o5ggc3v5wr2eyuckstlpvxhzvhnmbgpqoz6dl6q"
    boot_volume_size_in_gbs         = "200"
    boot_volume_vpus_per_gb         = "120"
    is_preserve_boot_volume_enabled = false
  }

  create_vnic_details {
    subnet_id = oci_core_subnet.public.id
    # 作成時に指定しても OCI が自動の名前（vnic + 日時）を付けるので、作成後に apply をもう 1 回して揃える
    private_ip       = "10.0.0.151"
    assign_public_ip = "true" # エフェメラル Public IP（作り直すと変わる）
    assign_ipv6ip    = false
    # VCN 内の DNS 名は使わないので登録しない（そのため hostname_label も書かない。書くと作成時に API がエラーにする）
    assign_private_dns_record = false
    skip_source_dest_check    = false
    nsg_ids                   = []
    freeform_tags             = local.tags
    security_attributes       = {}
  }

  agent_config {
    are_all_plugins_disabled = false
    is_management_disabled   = false
    is_monitoring_disabled   = false

    plugins_config {
      name          = "Vulnerability Scanning"
      desired_state = "DISABLED"
    }
    plugins_config {
      name          = "Management Agent"
      desired_state = "DISABLED"
    }
    plugins_config {
      name          = "Custom Logs Monitoring"
      desired_state = "ENABLED"
    }
    plugins_config {
      name          = "Compute RDMA GPU Monitoring"
      desired_state = "DISABLED"
    }
    plugins_config {
      name          = "Compute Instance Monitoring"
      desired_state = "ENABLED"
    }
    plugins_config {
      name          = "Compute HPC RDMA Auto-Configuration"
      desired_state = "DISABLED"
    }
    plugins_config {
      name          = "Compute HPC RDMA Authentication"
      desired_state = "DISABLED"
    }
    plugins_config {
      name          = "Cloud Guard Workload Protection"
      desired_state = "ENABLED"
    }
    plugins_config {
      name          = "Block Volume Management"
      desired_state = "DISABLED"
    }
    plugins_config {
      name          = "Bastion"
      desired_state = "DISABLED"
    }
  }

  availability_config {
    is_live_migration_preferred = false
    recovery_action             = "RESTORE_INSTANCE"
  }

  # 古い形式のメタデータ取得（IMDSv1）を無効にし、v2（/opc/v2/ + Authorization ヘッダ必須）だけにする
  # URL しか操れない SSRF でメタデータを読まれるのを防ぐ（cloud-init・Oracle Cloud Agent は v2 に対応）
  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  # is_pv_encryption_in_transit_enabled は作成時には効かない（作成時は上のトップレベルの値が使われる）
  launch_options {
    boot_volume_type                    = "PARAVIRTUALIZED"
    firmware                            = "UEFI_64"
    network_type                        = "PARAVIRTUALIZED"
    remote_data_volume_type             = "PARAVIRTUALIZED"
    is_consistent_volume_naming_enabled = true
    is_encryption_in_transit_enabled    = false
    is_pv_encryption_in_transit_enabled = true
  }

  lifecycle {
    # 作り直し（destroy）を含む plan はエラーにする
    prevent_destroy = true

    ignore_changes = [
      defined_tags,                        # OCI が自動で付けるタグ
      create_vnic_details[0].defined_tags, # 同上（VNIC 側）
      metadata,                            # SSH 鍵と user_data は起動後に API で変更できない
      source_details[0].source_id,         # イメージを変えると作り直しになる
    ]
  }
}
