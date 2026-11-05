#!/bin/zsh
# 画面収録などの TCC は、アドホック署名だと設定画面がオンでも拒否されることがある。
# 同じ自己署名の Code Signing 証明書で毎回サインするための identity を作る。
set -euo pipefail

SECURITY=/usr/bin/security
OPENSSL=/usr/bin/openssl

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERT_NAME="local-transcription-dev"
KEYCHAIN="$HOME/Library/Keychains/local-transcription-signing.keychain-db"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
PASS_FILE="$ROOT/.signing/signing-keychain-pass"
PASS="local-transcription-signing"

mkdir -p "$(dirname "$PASS_FILE")"
printf '%s\n' "$PASS" > "$PASS_FILE"
chmod 600 "$PASS_FILE"

"$SECURITY" list-keychains -d user -s "$KEYCHAIN" "$LOGIN_KEYCHAIN"

if [[ ! -f "$KEYCHAIN" ]]; then
  "$SECURITY" create-keychain -p "$PASS" "$KEYCHAIN"
fi
"$SECURITY" set-keychain-settings -lut 21600 "$KEYCHAIN" || true
"$SECURITY" unlock-keychain -p "$PASS" "$KEYCHAIN"
"$SECURITY" list-keychains -d user -s "$KEYCHAIN" "$LOGIN_KEYCHAIN"

trust_cert() {
  local pem=$1
  # 自己署名はデフォルトで NOT_TRUSTED。コード署名ポリシーだけ信頼する。
  # パスワードまたは Touch ID を求められることがある。
  "$SECURITY" add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$pem"
}

ensure_valid() {
  if "$SECURITY" find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -F "$CERT_NAME" >/dev/null; then
    return 0
  fi
  return 1
}

if ensure_valid; then
  echo "already have identity: $CERT_NAME"
  "$SECURITY" find-identity -v -p codesigning "$KEYCHAIN" | grep -F "$CERT_NAME" || true
  exit 0
fi

# 以前 import 済みで信頼だけ足りない場合
if "$SECURITY" find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -F "$CERT_NAME" >/dev/null; then
  echo "identity はあるが未信頼なので、コード署名用に信頼します（確認ダイアログが出ることがあります）"
  TMPDIR=$(mktemp -d)
  trap 'rm -rf "$TMPDIR"' EXIT
  "$SECURITY" find-certificate -c "$CERT_NAME" -p "$KEYCHAIN" > "$TMPDIR/cert.pem"
  trust_cert "$TMPDIR/cert.pem"
  if ensure_valid; then
    echo "trusted identity: $CERT_NAME"
    "$SECURITY" find-identity -v -p codesigning "$KEYCHAIN" | grep -F "$CERT_NAME"
    exit 0
  fi
  echo "信頼設定後も valid になりませんでした" >&2
  "$SECURITY" find-identity -p codesigning "$KEYCHAIN" >&2 || true
  exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
cat > "$TMPDIR/cert.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = ${CERT_NAME}
[v3_req]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:FALSE
EOF

"$OPENSSL" req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
  -config "$TMPDIR/cert.cnf" -extensions v3_req \
  -keyout "$TMPDIR/key.pem" -out "$TMPDIR/cert.pem"

# macOS 付属の LibreSSL は -legacy 非対応。デフォルトの 3DES で出す。
"$OPENSSL" pkcs12 -export -out "$TMPDIR/cert.p12" \
  -inkey "$TMPDIR/key.pem" -in "$TMPDIR/cert.pem" \
  -passout pass:temp \
  -name "$CERT_NAME"

"$SECURITY" import "$TMPDIR/cert.p12" -k "$KEYCHAIN" -P temp \
  -T /usr/bin/codesign -T /usr/bin/security
"$SECURITY" set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null

echo "コード署名用に信頼します（確認ダイアログが出ることがあります）"
trust_cert "$TMPDIR/cert.pem"

if ! ensure_valid; then
  echo "identity の作成に失敗しました" >&2
  "$SECURITY" find-identity -p codesigning "$KEYCHAIN" >&2 || true
  exit 1
fi

echo "created identity: $CERT_NAME"
"$SECURITY" find-identity -v -p codesigning "$KEYCHAIN" | grep -F "$CERT_NAME"
echo "keychain: $KEYCHAIN"
