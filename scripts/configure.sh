#!/usr/bin/env bash
# Writes capacitor.config.json from the template with the talk URL filled in.
# The URL carries the page secret, so it lives ONLY in the environment
# (GitHub secret TALK_URL in CI, or a mock server locally) — never in git.
set -euo pipefail
cd "$(dirname "$0")/.."
url="${TALK_URL:-}"
if [ -z "$url" ]; then
  echo "configure: TALK_URL is empty — refusing to write a config that loads nothing" >&2
  exit 2
fi
case "$url" in
  https://*|http://127.0.0.1:*|http://localhost:*|http://10.*|http://192.168.*) ;;
  *) echo "configure: TALK_URL must be https:// (or a local mock)" >&2; exit 2 ;;
esac
# no printing of the URL: it is a secret
python3 - "$url" <<'PY'
import json, sys
url = sys.argv[1]
cfg = json.load(open("capacitor.config.template.json"))
cfg["server"]["url"] = url
json.dump(cfg, open("capacitor.config.json", "w"), indent=2)
PY
echo "configure: wrote capacitor.config.json (url host: $(python3 -c 'import sys,urllib.parse as u;print(u.urlsplit(sys.argv[1]).netloc)' "$url"))"
