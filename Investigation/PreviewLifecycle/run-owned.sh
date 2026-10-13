#!/bin/bash
# Exercise only an absent Preview directory that this process exclusively creates.
set -euo pipefail
cd "$(dirname "$0")/../.."
export BOUTIQUE_SWIFT="${BOUTIQUE_SWIFT:-swift}"
preview_directory=$("$BOUTIQUE_SWIFT" -e 'import Foundation; print(URL.temporaryDirectory.appendingPathComponent("Previews").path)')
# mkdir without -p is exclusive. Existing user data is a hard stop.
mkdir "$preview_directory"
export BOUTIQUE_PREVIEW_OWNED_DIRECTORY="$preview_directory"
export BOUTIQUE_PREVIEW_OWNER_TOKEN="$(uuidgen)"
printf '%s' "$BOUTIQUE_PREVIEW_OWNER_TOKEN" > "$preview_directory/.boutique-preview-owner"
cleanup() {
  python3 - "$preview_directory" "$BOUTIQUE_PREVIEW_OWNER_TOKEN" <<'PY'
import pathlib, sys
root=pathlib.Path(sys.argv[1]); marker=root/'.boutique-preview-owner'
if root.is_symlink() or not marker.is_file() or marker.read_text()!=sys.argv[2]:
    raise SystemExit('Ownership changed; refusing cleanup')
allowed={'.boutique-preview-owner','data.sqlite3','data.sqlite3-journal','data.sqlite3-wal','data.sqlite3-shm'}
children=list(root.iterdir())
if any(p.name not in allowed or p.is_symlink() or not p.is_file() for p in children):
    raise SystemExit('Unexpected artifacts; refusing cleanup')
print('OWNED PREVIEW artifacts: '+', '.join(p.name for p in children))
for p in children: p.unlink()
root.rmdir()
PY
}
trap cleanup EXIT
export BOUTIQUE_TEST_REVISION="$(git rev-parse HEAD)"
if ! git diff --quiet || ! git diff --cached --quiet; then BOUTIQUE_TEST_REVISION+="-dirty"; fi
"$BOUTIQUE_SWIFT" test --jobs 2 --filter "${BOUTIQUE_PREVIEW_TEST_FILTER:-StorePreviewLifecycle}" "$@"
