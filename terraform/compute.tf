# インスタンスの作成時に使う OS イメージ（Canonical Ubuntu 26.04 Minimal の aarch64 版のうち、いちばん新しいもの）
# Minimal 版は入っているパッケージが少ない（gpg やエディタがない）。必要なものは cloud-init で入れる
# source_id は ignore_changes なので、新しいイメージが出ても今のインスタンスは作り直されない（作り直したときにだけ効く）
data "oci_core_images" "ubuntu" {
  compartment_id           = local.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "26.04 Minimal aarch64"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"

  lifecycle {
    postcondition {
      condition     = length(self.images) > 0
      error_message = "Canonical Ubuntu 26.04 Minimal aarch64 のイメージが見つかりません。"
    }
  }
}

# n8n + cloudflared を動かしているインスタンス（Always Free の A1 枠 4 OCPU / 24 GB をすべて使用）
# 作り直すと A1 の空き容量不足で同じ構成を確保し直せないおそれがあるため、destroy を禁止している
#
# n8n のデータはブロックボリューム（下の oci_core_volume.n8n_data）にあるので、作り直しても残る
# 作り直すとき（OS イメージを変えるときなど）の手順:
#   1. この下の lifecycle の prevent_destroy を一時的に false にする（コミットしない）
#   2. terraform apply -replace=oci_core_instance.n8n
#      （古いインスタンスとブートボリュームを消してから作る。ブロックボリュームは残り、新しいインスタンスに付け直される）
#      A1 の空きがない（Out of host capacity）・ボリュームの上限（LimitExceeded）で失敗したら、時間をおいて terraform apply をやり直す
#   3. prevent_destroy を true に戻す
#   4. サーバーで cloud-init status --wait のあと、~/n8n で
#      sudo ./setup-data-volume.sh → ./create-env.sh → sudo docker compose up -d
resource "oci_core_instance" "n8n" {
  compartment_id      = local.compartment_id
  availability_domain = local.availability_domain
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
  # ブートボリュームにあるのは OS と ~/n8n（リポジトリと .env）だけ。n8n のデータはブロックボリュームにあるので消えない
  preserve_boot_volume = false

  metadata = {
    ssh_authorized_keys = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCyLBTdOgiofvADIgG4CpjpxMkTb/LMTCcGTNV6/K30NT+MIkJq5QL4fDMy3VcakblEKUhIh8lKlrqJ4H7LhYRsEqzJC0Q4aBkeOyarv0HVoB7XPa4ct5Ozy4+8pX+gbi8j/oRfkafJZWvMpR4RVckwq9C9rT/YZG+uSa8alEOZXeLRTGU6ka4KyKaOftbClCWvBl6U0K+A8Hlv/HxoeY09cg/jo8INzAWHV1g3nh1mxMcTTLb+6CzPedMxTfOdpe9cfGGuq44YJaaixnKbM8VH4Z7DWFhEOdzLq8hflxM6Lo2J3s/IMe9PP0uH87+l/HKthRO10B6YNRacsNrfu+lH ssh-key-2026-03-31"

    # 初回起動時の設定（シリアル・コンソール用パスワード、Docker のインストール、UDP バッファの上限、リポジトリの取得）。作り直すときにだけ効く
    # metadata は ignore_changes なので、書き換えても今のインスタンスには反映されない（作り直したときに効く）
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
      password_hash  = var.console_password_hash
      docker_apt_key = file("${path.module}/docker.asc")
    }))
  }

  # local_volume_size_in_gbs と nvmes はローカル NVMe 付きのシェイプ用（A1 にはない）
  # import したときは 0 が入っていたが、作成時に 0 を渡すと API がエラーにするので書かない
  shape_config {
    ocpus         = 4
    memory_in_gbs = 24
    vcpus         = 4
  }

  # ブートボリュームは OCI の最小の 50 GB にし、残りの 150 GB をブロックボリュームに回す
  # （Always Free の枠はブートとブロックを合わせて 200 GB。Always Free のドキュメントにある「50 GB + 150 GB」の構成）
  # ボリュームは大きくはできるが小さくはできないので、ここを減らすには作り直すしかない
  # 性能は 120（Ultra High Performance の最大）
  source_details {
    source_type                     = "image"
    source_id                       = data.oci_core_images.ubuntu.images[0].id
    boot_volume_size_in_gbs         = "50"
    boot_volume_vpus_per_gb         = "120"
    is_preserve_boot_volume_enabled = false
  }

  create_vnic_details {
    subnet_id = oci_core_subnet.public.id
    # 名前（display_name）は書かない。作成時に指定しても VNIC には OCI が自動の名前（vnic + 日時）を付けるため
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
    # テナンシの Cloud Guard を使っていない（無効）ので、このプラグインも動かさない
    plugins_config {
      name          = "Cloud Guard Workload Protection"
      desired_state = "DISABLED"
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

# n8n のデータ（SQLite のデータベース・暗号化キーなど）を置くブロックボリューム
# サーバーでは /srv/n8n にマウントし（setup-data-volume.sh）、docker-compose.yml で n8n の /home/node/.n8n につなぐ
# インスタンスとは別のリソースなので、インスタンスを作り直しても消えず、新しいインスタンスに付け直すだけで使える
# そのため destroy を禁止している（消すとデータも消える）
resource "oci_core_volume" "n8n_data" {
  compartment_id      = local.compartment_id
  availability_domain = local.availability_domain
  # ブートボリュームの 50 GB と合わせて、Always Free の 200 GB 枠を使い切る
  size_in_gbs = "150"
  # 性能は 120（Ultra High Performance の最大）
  vpus_per_gb   = "120"
  freeform_tags = local.tags

  # インスタンスの値は使っていないが、作るのはインスタンスの後にする
  # 200 GB のブートボリュームが残っているうちに作ると、一時的に Always Free の 200 GB 枠を超えるため
  # （今のインスタンスを作り直してブートボリュームを 50 GB にする、最初の apply のときに効く）
  depends_on = [oci_core_instance.n8n]

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [defined_tags] # OCI が自動で付けるタグ
  }
}

# ブロックボリュームをインスタンスに付ける
# 準仮想化（paravirtualized）なら、OS で iSCSI のコマンドを打たなくても、付けた時点でディスク（/dev/sdb など）として見える
# （そのため Oracle Cloud Agent の Block Volume Management プラグインは無効のままでよい）
# インスタンスを作り直すと、これも作り直される（古いインスタンスから外し、新しいインスタンスに付ける）
resource "oci_core_volume_attachment" "n8n_data" {
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.n8n.id
  volume_id       = oci_core_volume.n8n_data.id
  # ブートボリュームと同じく、ボリュームとの通信を暗号化する
  is_pv_encryption_in_transit_enabled = true
}
