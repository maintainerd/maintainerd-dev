#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CERT_DIR="${ROOT_DIR}/.certs"
CA_KEY="${CERT_DIR}/maintainerd-local-ca.key"
CA_CERT="${CERT_DIR}/maintainerd-local-ca.crt"
TLS_KEY="${CERT_DIR}/auth.maintainerd.local.key"
TLS_CSR="${CERT_DIR}/auth.maintainerd.local.csr"
TLS_CERT="${CERT_DIR}/auth.maintainerd.local.crt"

configure_firefox_system_trust() {
  local roots=(
    "${HOME}/.mozilla/firefox"
    "${HOME}/snap/firefox/common/.mozilla/firefox"
  )
  local root profile user_js configured="false"

  for root in "${roots[@]}"; do
    [ -d "$root" ] || continue
    while IFS= read -r -d '' cert_db; do
      profile="$(dirname "$cert_db")"
      user_js="${profile}/user.js"

      # Firefox Snap uses its own NSS database by default. This preference
      # makes it consume the CA installed in Ubuntu's system trust store.
      if [ -f "$user_js" ]; then
        sed -i '/user_pref("security\.enterprise_roots\.enabled"/d' "$user_js"
      fi
      printf '%s\n' 'user_pref("security.enterprise_roots.enabled", true);' >> "$user_js"
      echo "  [TRUST] Enabled system CA trust for Firefox profile: ${profile}"
      configured="true"
    done < <(find "$root" -mindepth 2 -maxdepth 2 -type f -name cert9.db -print0)
  done

  if [ "$configured" = "true" ]; then
    echo "  [NOTE] Fully restart Firefox to load the local CA"
  fi
}

mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

if [ ! -s "$CA_KEY" ] || [ ! -s "$CA_CERT" ]; then
  echo "  [CREATE] Maintainerd local certificate authority"
  openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days 3650 \
    -keyout "$CA_KEY" \
    -out "$CA_CERT" \
    -subj "/CN=Maintainerd Local Development CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
fi

if [ ! -s "$TLS_KEY" ] || [ ! -s "$TLS_CERT" ] || \
   ! openssl x509 -checkend 2592000 -noout -in "$TLS_CERT" >/dev/null 2>&1; then
  echo "  [CREATE] Wildcard certificate for *.auth.maintainerd.local"
  openssl req -new -newkey rsa:2048 -sha256 -nodes \
    -keyout "$TLS_KEY" \
    -out "$TLS_CSR" \
    -subj "/CN=*.auth.maintainerd.local" \
    -addext "subjectAltName=DNS:*.auth.maintainerd.local,DNS:auth.maintainerd.local"

  openssl x509 -req -sha256 -days 825 \
    -in "$TLS_CSR" \
    -CA "$CA_CERT" \
    -CAkey "$CA_KEY" \
    -CAcreateserial \
    -copy_extensions copy \
    -out "$TLS_CERT"
  rm -f "$TLS_CSR"
fi

chmod 600 "$CA_KEY" "$TLS_KEY"
chmod 644 "$CA_CERT" "$TLS_CERT"

if [ "${1:-}" = "--trust" ]; then
  SYSTEM_CA=/usr/local/share/ca-certificates/maintainerd-local-ca.crt
  if [ -f "$SYSTEM_CA" ] && cmp -s "$CA_CERT" "$SYSTEM_CA"; then
    echo "  [SKIP] Maintainerd local CA is already trusted"
  else
    echo "  [TRUST] Installing Maintainerd local CA into the system trust store"
    sudo install -m 0644 "$CA_CERT" "$SYSTEM_CA"
    sudo update-ca-certificates
  fi
  configure_firefox_system_trust
fi

echo "  [DONE] Local HTTPS certificate is ready"
