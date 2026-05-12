#!/usr/bin/env bash
# One-time setup: create a persistent self-signed code-signing identity
# for local WhisperM8 builds.
#
# Why: ad-hoc signing (`codesign --sign -`) makes the binary hash the
# code identity. Every `make dev` produces a different hash, so macOS
# TCC ("Files and Folders" permissions) treats each build as a new app
# and re-prompts for Photos / Desktop / Downloads / Documents / Network
# Volumes access. With a persistent signing cert, the designated
# requirement is bound to the cert (stable across builds) and TCC
# grants survive rebuilds.
#
# Idempotent: re-running this script does nothing if the cert already
# exists.

set -euo pipefail

CERT_NAME="WhisperM8 Local Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
TMPDIR=$(mktemp -d -t whisperm8-codesign-cert)
trap 'rm -rf "$TMPDIR"' EXIT

if security find-certificate -c "$CERT_NAME" -p > /dev/null 2>&1; then
    echo "✔ Certificate '$CERT_NAME' already exists in the login keychain."
    echo "  Nothing to do. If you want to rotate it, remove it first via Keychain Access."
    exit 0
fi

echo "→ Generating private key + self-signed code-signing certificate..."

# Self-signed cert valid for 100 years (overkill but easy).
# The codeSigning extendedKeyUsage is what makes `codesign` accept it.
openssl req -newkey rsa:2048 -nodes \
    -keyout "$TMPDIR/codesign.key" \
    -x509 -days 36500 \
    -subj "/CN=${CERT_NAME}" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -out "$TMPDIR/codesign.crt" 2> /dev/null

# Bundle key+cert into PKCS12 with a fixed transient password.
# macOS rejects empty-password p12s on import; the password is only
# used to bundle the key, it is not stored anywhere afterward.
P12_PASS="whisperm8-local-dev"
# Use legacy PBE so macOS Security framework can decode the file.
# OpenSSL 3 defaults to AES-256-CBC + PBKDF2 which the macOS importer
# can't verify. -legacy + explicit SHA1-3DES gives us the old format
# that `security import` understands.
openssl pkcs12 -export \
    -legacy \
    -keypbe PBE-SHA1-3DES \
    -certpbe PBE-SHA1-3DES \
    -macalg sha1 \
    -inkey "$TMPDIR/codesign.key" \
    -in "$TMPDIR/codesign.crt" \
    -name "$CERT_NAME" \
    -password "pass:$P12_PASS" \
    -out "$TMPDIR/codesign.p12"

echo "→ Importing into login keychain..."
# -T /usr/bin/codesign whitelists codesign to use the private key without
# a confirmation prompt at sign time.
security import "$TMPDIR/codesign.p12" \
    -k "$KEYCHAIN" \
    -P "$P12_PASS" \
    -T /usr/bin/codesign \
    -A > /dev/null

echo "→ Marking certificate as trusted for code signing..."
# User-keychain trust — no sudo needed. codesign will pick this up via
# `security find-identity -p codesigning`. macOS TCC then binds grants
# to the cert's designated requirement, surviving rebuilds.
security add-trusted-cert -r trustRoot -p codeSign \
    -k "$KEYCHAIN" "$TMPDIR/codesign.crt"

# Update partition list so codesign can access the key without GUI
# prompts on each invocation.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" > /dev/null 2>&1 || true

echo ""
echo "✔ Done. Identity '$CERT_NAME' is now available for codesigning."
echo "  Verify with:  codesign -dvv \"\$(security find-identity -p codesigning -v | grep '$CERT_NAME' | head -1)\""
echo ""
echo "Next steps:"
echo "  1. Run 'make dev' — it will use the new identity automatically."
echo "  2. Re-grant any TCC prompts that appear ONCE. They'll stick across rebuilds."
