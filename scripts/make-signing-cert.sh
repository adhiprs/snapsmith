#!/bin/sh
# One-time setup: creates a self-signed code-signing certificate in your login keychain.
#
# Why: ad-hoc signed apps are identified by their exact code hash, so every rebuild loses
# the Screen Recording permission. Signed with a stable certificate, macOS identifies
# SnapSmith by bundle ID + certificate instead, and the permission survives rebuilds.
#
# The private key never leaves your keychain; temporary files are deleted on exit.
set -eu

NAME="SnapSmith Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Certificate \"$NAME\" already exists. Nothing to do."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# 10-year certificate; it only signs your own local builds.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
    -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

# PKCS#12 needs a password for `security import`; it only lives for this script run.
P12_PASS=$(openssl rand -hex 16)
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -passout "pass:$P12_PASS" -out "$TMP/cert.p12"

# -T lets codesign use the key without asking each time.
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign >/dev/null

# Trust it for code signing (user trust settings only, not system-wide).
# macOS asks for your login password once here.
echo "macOS will ask for your password to trust the certificate for code signing..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo "Created \"$NAME\"."
security find-identity -v -p codesigning | grep "$NAME"
