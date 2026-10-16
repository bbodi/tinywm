#!/bin/bash
# Creates a self-signed code-signing identity in your login keychain, once.
#
# Signing every build with the same identity keeps macOS's Accessibility and Screen Recording
# grants across updates. It is not an Apple Developer ID, so a downloaded copy still needs
# "Open Anyway" once. macOS asks for your password to trust the certificate for code signing.
#
# Keep a backup: Keychain Access → login → My Certificates → export "tinywm self-signed" as .p12.
# Releases signed by a different certificate lose users' permission grants.
set -euo pipefail

NAME="${1:-tinywm self-signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "\"$NAME\" already exists in the login keychain."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS="$(openssl rand -hex 16)"

cat > "$TMP/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
# Older PKCS#12 ciphers, because the keychain cannot read the newer defaults.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:$PASS" -out "$TMP/identity.p12"

security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo "Created \"$NAME\". scripts/bundle-tinywm.sh now signs with it automatically."
