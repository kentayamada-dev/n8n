#!/usr/bin/env bash
# workflows/ のワークフローを n8n に取り込む（サーバーの ~/n8n で ./import-workflows.sh と実行する）
#
# 使う前に、画面でオーナーと認証情報を作っておく
# 認証情報は前と同じ「名前と種類」にする（取り込む前に、必要な名前と種類の一覧を表示する）
# JSON にある認証情報の ID が見つからないとき、n8n は同じ名前・同じ種類の認証情報が 1 つだけあれば、それに付け替える
#
# n8n の CLI（import:workflow）で取り込むので、ワークフローの ID と Slack トリガーの webhookId は JSON のまま残る
# 同じ ID のワークフローは上書きされる。取り込んだワークフローはすべて無効になるので、画面で有効にする
# 起動のたびに自動では取り込まない（画面で直してまだバックアップしていない変更が、上書きで消えるため）
#
# 画面に出す文字は英語（ASCII）にする
# シリアル・コンソールは出力のバイトを取りこぼすことがあり、日本語（UTF-8 で 1 文字 3 バイト）は化けやすいため
# （n8n 自身が出すメッセージにはワークフロー名が入るので、そこは化けることがある）
set -euo pipefail

# docker-compose.yml と workflows/ がある場所で実行する
cd "$(dirname "$0")"

# ubuntu ユーザーは docker グループに入っていないので、docker を直接使えなければ sudo を付ける
# docker compose exec は標準入力を読んでしまい、下の確認（y/N）への入力を横取りするので、/dev/null をつなぐ
if docker info >/dev/null 2>&1; then
  compose() { docker compose "$@" </dev/null; }
else
  compose() { sudo docker compose "$@" </dev/null; }
fi

shopt -s nullglob
files=(workflows/*.json)
if (( ${#files[@]} == 0 )); then
  echo 'No workflows/*.json found.' >&2
  exit 1
fi

# JSON の下ごしらえ（n8n のコンテナにある node で動かす。サーバーに jq などを入れなくて済むように）
#   list:  ワークフローが使う認証情報の「名前 (種類)」を一覧にする
#   strip: API で書き出した JSON に入っている、前の n8n のデータを指す項目を消す
#          shared（前のプロジェクト）と activeVersion（前の版の履歴）が残っていると、
#          取り込みが「FOREIGN KEY constraint failed」で失敗する
prepare_js='
const fs = require("fs"), path = require("path");
const [mode, dir] = process.argv.slice(1);
const files = fs.readdirSync(dir).filter((f) => f.endsWith(".json"));
const creds = new Set();
for (const f of files) {
  const p = path.join(dir, f);
  const wf = JSON.parse(fs.readFileSync(p, "utf8"));
  if (mode === "list") {
    for (const node of wf.nodes || [])
      for (const [type, c] of Object.entries(node.credentials || {})) creds.add(`${c.name} (${type})`);
  } else {
    delete wf.shared;
    delete wf.activeVersion;
    fs.writeFileSync(p, JSON.stringify(wf));
  }
}
if (mode === "list") for (const c of [...creds].sort()) console.log(`  ${c}`);
'

# コンテナの中の一時ディレクトリに workflows/ を写して使う（n8n のコンテナには workflows/ をマウントしていないため）
# 途中で止まっても中止しても、最後に必ず消す
tmp="/tmp/n8n-import-workflows-$$"
cleanup() { compose exec -T -u root n8n rm -rf "$tmp" >/dev/null 2>&1 || true; }
trap cleanup EXIT

compose cp workflows "n8n:$tmp" >/dev/null 2>&1
compose exec -T -u root n8n chown -R node:node "$tmp"

echo "Workflows to import: ${#files[@]}"
echo 'Credentials they use (create these with the same name and type before importing):'
compose exec -T -u node n8n node -e "$prepare_js" list "$tmp"
# 入力が終わっている（EOF）ときは「いいえ」として扱う
read -rp 'Workflows with the same ID will be overwritten. Import? [y/N] ' answer || answer=''
if [[ "$answer" != [yY] ]]; then
  echo 'Aborted. Nothing was imported.'
  exit 1
fi

compose exec -T -u node n8n node -e "$prepare_js" strip "$tmp"
compose exec -T -u node n8n n8n import:workflow --separate --input="$tmp"

echo 'Done. All imported workflows are inactive.'
echo 'Next: open n8n, check each credential is linked, then activate the workflows.'
echo 'If you overwrote workflows that were active, restart n8n so old schedules stop:'
echo '  sudo docker compose restart n8n'
