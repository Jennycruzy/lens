#!/usr/bin/env bash
# Copies the static explorer to the nginx document root on this host.
# The page is plain files; there is nothing to build beyond regenerating config.js.
set -euo pipefail
cd "$(dirname "$0")/.."
node tools/build-web-config.mjs --check
node tools/web-static.mjs >/dev/null
sudo rsync -a --delete web/ /var/www/lens/
sudo chown -R www-data:www-data /var/www/lens
echo "published to https://lens.54-154-121-30.sslip.io"
