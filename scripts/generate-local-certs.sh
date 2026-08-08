#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CERT_DIR="${ROOT_DIR}/.certs"
CA_KEY="${CERT_DIR}/maintainerd-local-ca.key"
CA_CERT="${CERT_DIR}/maintainerd-local-ca.crt"
TLS_KEY="${CERT_DIR}/auth.maintainerd.local.key"
TLS_CSR="${CERT_DIR}/auth.maintainerd.local.csr"
TLS_CERT="${CERT_DIR}/auth.maintainerd.local.crt"

# gRPC mTLS material (service-to-service). Signed by the same local CA so a
# single trust root covers HTTPS and gRPC. The dir is mounted into the auth
# container; client.{crt,key} are for testing from the host (e.g. grpcurl).
GRPC_DIR="${CERT_DIR}/grpc"
GRPC_CA_CERT="${GRPC_DIR}/ca.crt"
GRPC_SERVER_KEY="${GRPC_DIR}/server.key"
GRPC_SERVER_CSR="${GRPC_DIR}/server.csr"
GRPC_SERVER_CERT="${GRPC_DIR}/server.crt"
GRPC_CLIENT_KEY="${GRPC_DIR}/client.key"
GRPC_CLIENT_CSR="${GRPC_DIR}/client.csr"
GRPC_CLIENT_CERT="${GRPC_DIR}/client.crt"

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
  # SANs cover each host tier (TLS wildcards match a single label, so every
  # depth with tenant subdomains needs its own wildcard):
  #   auth.maintainerd.local             base (WebAuthn RP ID / shared suffix)
  #   *.auth.maintainerd.local           fixed single-label hosts: identity.auth,
  #                                      console.auth, identity-api.auth, console-api.auth
  #   *.console.auth.maintainerd.local   {tenant}.console.auth (console tenants)
  #   *.identity.auth.maintainerd.local  {tenant}.identity.auth (identity/login tenants)
  openssl req -new -newkey rsa:2048 -sha256 -nodes \
    -keyout "$TLS_KEY" \
    -out "$TLS_CSR" \
    -subj "/CN=*.auth.maintainerd.local" \
    -addext "subjectAltName=DNS:*.auth.maintainerd.local,DNS:auth.maintainerd.local,DNS:*.console.auth.maintainerd.local,DNS:*.identity.auth.maintainerd.local"

  openssl x509 -req -sha256 -days 825 \
    -in "$TLS_CSR" \
    -CA "$CA_CERT" \
    -CAkey "$CA_KEY" \
    -CAcreateserial \
    -copy_extensions copy \
    -out "$TLS_CERT"
  rm -f "$TLS_CSR"
fi

if [ ! -s "$GRPC_SERVER_KEY" ] || [ ! -s "$GRPC_SERVER_CERT" ] || \
   [ ! -s "$GRPC_CLIENT_CERT" ] || \
   ! openssl x509 -checkend 2592000 -noout -in "$GRPC_SERVER_CERT" >/dev/null 2>&1; then
  echo "  [CREATE] gRPC mTLS server + client certificates"
  mkdir -p "$GRPC_DIR"
  # 755, not 700: the all-in-one RELEASE image runs as a non-root user (uid
  # 65532) and mounts this dir read-only. A 700 dir owned by the host user blocks
  # that uid from even traversing it, so the container fails to read ca.crt /
  # server.* and crash-loops. The dev backend runs as root and never hit this.
  chmod 755 "$GRPC_DIR"

  # Self-contained trust root inside the mounted dir (GRPC_CLIENT_CA_FILE).
  cp "$CA_CERT" "$GRPC_CA_CERT"

  # Server cert — SANs cover every name a gRPC client might dial:
  #   localhost / 127.0.0.1        host tools (grpcurl) against the exposed port
  #   maintainerd-auth, m9d-auth-dev   other containers on the compose network
  openssl req -new -newkey rsa:2048 -sha256 -nodes \
    -keyout "$GRPC_SERVER_KEY" \
    -out "$GRPC_SERVER_CSR" \
    -subj "/CN=maintainerd-auth-grpc" \
    -addext "subjectAltName=DNS:localhost,DNS:maintainerd-auth,DNS:maintainerd-auth-release,DNS:m9d-auth-dev,IP:127.0.0.1" \
    -addext "extendedKeyUsage=serverAuth"
  openssl x509 -req -sha256 -days 825 \
    -in "$GRPC_SERVER_CSR" \
    -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
    -copy_extensions copy \
    -out "$GRPC_SERVER_CERT"

  # Client cert — presented by callers; verified by the server against the CA.
  openssl req -new -newkey rsa:2048 -sha256 -nodes \
    -keyout "$GRPC_CLIENT_KEY" \
    -out "$GRPC_CLIENT_CSR" \
    -subj "/CN=maintainerd-grpc-client" \
    -addext "extendedKeyUsage=clientAuth"
  openssl x509 -req -sha256 -days 825 \
    -in "$GRPC_CLIENT_CSR" \
    -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
    -copy_extensions copy \
    -out "$GRPC_CLIENT_CERT"

  rm -f "$GRPC_SERVER_CSR" "$GRPC_CLIENT_CSR"
  # server.key is read by the auth container (GRPC_TLS_KEY_FILE), which in the
  # release image is non-root — so it must be world-readable (644). client.key is
  # only ever used by host tooling (grpcurl), so it stays owner-only (600). This
  # is a throwaway local CA, so a readable server key on your own machine is fine.
  chmod 644 "$GRPC_SERVER_KEY"
  chmod 600 "$GRPC_CLIENT_KEY"
  chmod 644 "$GRPC_CA_CERT" "$GRPC_SERVER_CERT" "$GRPC_CLIENT_CERT"
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

echo "  [DONE] Local HTTPS + gRPC mTLS certificates are ready"
