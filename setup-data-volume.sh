#!/usr/bin/env bash
# n8n のデータ用のブロックボリュームを /srv/n8n にマウントする（サーバーの ~/n8n で sudo ./setup-data-volume.sh と実行する）
#
# インスタンスを作ったら（作り直したら）、docker compose up の前に 1 回実行する
#   - ボリュームが空（新しく作ったばかり）のときだけフォーマットする。データが入っていればそのまま使う
#   - /etc/fstab に登録するので、次の起動からは自動でマウントされる
#   - 何度実行してもよい（済んでいる作業は飛ばす）
#
# n8n は /srv/n8n/data を使う（docker-compose.yml）。data はこのボリュームの中にしかないので、
# マウントできていないときは n8n が起動せずにエラーになる（空のディレクトリでデータを作り直さないように）
#
# 画面に出す文字は英語（ASCII）にする
# シリアル・コンソールは出力のバイトを取りこぼすことがあり、日本語（UTF-8 で 1 文字 3 バイト）は化けやすいため
set -euo pipefail

# ファイルシステムのラベル。デバイス名（/dev/sdb など）は付ける順番で変わることがあるので、ラベルで見分ける
label=n8n-data
mount_point=/srv/n8n
data_dir="$mount_point/data"
# n8n のコンテナは node ユーザー（UID 1000・GID 1000）で動く
n8n_uid=1000
n8n_gid=1000

if [[ $EUID -ne 0 ]]; then
  echo 'Run as root: sudo ./setup-data-volume.sh' >&2
  exit 1
fi

# --- ボリュームを見つける（なければフォーマットする） -------------------------------

# blkid -L は、そのラベルのファイルシステムがなければ何も出さずに失敗する
device="$(blkid -L "$label" || true)"

if [[ -n "$device" ]]; then
  echo "Found the data volume: $device (label $label)"
else
  # ラベルがない = 初めて使うボリューム。ブートボリューム（/ があるディスク）以外のディスクを探す
  # ちょうど 1 つでなければ、どれを使うか決められないので止める
  root_disk="$(lsblk -no PKNAME "$(findmnt -no SOURCE /)")"
  mapfile -t disks < <(lsblk -dno NAME,TYPE | awk -v root="$root_disk" '$2 == "disk" && $1 != root { print "/dev/" $1 }')

  if (( ${#disks[@]} == 0 )); then
    echo 'No data volume is attached.' >&2
    echo 'Check that terraform apply finished (oci_core_volume_attachment.n8n_data), then run this again.' >&2
    exit 1
  fi
  if (( ${#disks[@]} > 1 )); then
    echo "More than one extra disk is attached: ${disks[*]}" >&2
    echo 'Stopped without changing anything.' >&2
    exit 1
  fi
  device="${disks[0]}"

  # パーティションやファイルシステムなど、何か書かれていればフォーマットしない（データを消さないように）
  # wipefs -n は消さずに一覧だけ出す。何も出なければ空のディスク
  if [[ -n "$(wipefs -n "$device")" ]] || (( $(lsblk -no NAME "$device" | wc -l) > 1 )); then
    echo "$device is not empty, but it has no filesystem labeled $label." >&2
    echo 'Stopped without changing anything. Check the disk with: lsblk -f' >&2
    exit 1
  fi

  lsblk -dno NAME,SIZE,TYPE "$device"
  # 入力が終わっている（EOF）ときは「いいえ」として扱う
  read -rp "Format $device as ext4 (label $label)? [y/N] " answer || answer=''
  if [[ "$answer" != [yY] ]]; then
    echo 'Aborted. Nothing was changed.'
    exit 1
  fi
  # パーティションは切らず、ディスク全体を 1 つのファイルシステムにする
  # （OCI でボリュームを大きくしたあと、resize2fs だけで広げられる）
  mkfs.ext4 -q -L "$label" "$device"
  # 下の mount はラベル（/dev/disk/by-label/）で探すので、udev がラベルを登録し終わるのを待つ
  udevadm settle
  echo "Formatted $device"
fi

# --- /etc/fstab に登録してマウントする -------------------------------------------

# nofail: ボリュームが付いていなくても起動を止めない（緊急モードで止まると、シリアル・コンソールでしか直せない）
# そのときは data がないので n8n だけが起動に失敗する
fstab_line="LABEL=$label $mount_point ext4 defaults,nofail 0 2"
if ! grep -qE "^LABEL=$label[[:space:]]" /etc/fstab; then
  echo "$fstab_line" >> /etc/fstab
  echo "Added to /etc/fstab: $fstab_line"
  # fstab を書き換えたら、systemd に読み直させる（しないと mount が古い設定を見て警告を出す）
  systemctl daemon-reload
fi

mkdir -p "$mount_point"
if findmnt -rno SOURCE "$mount_point" >/dev/null; then
  echo "Already mounted: $mount_point"
else
  mount "$mount_point"
  echo "Mounted $device on $mount_point"
fi

# 別のものがマウントされていたら止める（data を作ってしまわないように）
if [[ "$(findmnt -rno LABEL "$mount_point")" != "$label" ]]; then
  echo "$mount_point is not the volume labeled $label. Check with: findmnt $mount_point" >&2
  exit 1
fi

# --- n8n のデータのディレクトリ ---------------------------------------------------

if [[ ! -d "$data_dir" ]]; then
  mkdir "$data_dir"
  echo "Created $data_dir"
fi
# n8n（node ユーザー）だけが読み書きできるようにする（暗号化キーや認証情報が入るため）
chown "$n8n_uid:$n8n_gid" "$data_dir"
chmod 700 "$data_dir"

echo 'Done. Disk usage:'
df -h "$mount_point"
echo 'Next: ./create-env.sh (if .env is missing), then sudo docker compose up -d'
