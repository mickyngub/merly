#!/bin/bash
# make-signing-cert.sh — create the stable local code-signing identity that
# scripts/bundle.sh signs with when no Developer ID is available.
#
# Why this exists: an ad-hoc signature (`codesign --sign -`) has a designated
# requirement of `cdhash H"<this exact build>"`, so **every rebuild is a different
# app** as far as macOS is concerned, and every Keychain "Always Allow" grant is
# re-prompted.
#
# A self-signed certificate fixes that: the requirement becomes
# `identifier "com.mickyngub.merlyn" and certificate leaf = H"<cert>"`, which
# survives rebuilds. It is purely local — a self-signed leaf is not a trusted
# anchor, so it does nothing for anyone else and is not a step toward distributing
# binaries.
#
# It does NOT govern notifications. That was measured, not assumed: an ad-hoc
# build and a stable-identity build of the same source were both refused with
# UNErrorDomain Code=1, while the same binary under a different bundle identifier
# was granted immediately. Notification permission tracks the bundle id, not the
# signature.
#
# Idempotent: re-running when the identity already exists is a no-op.
#
# Undo:  security delete-certificate -c "Merlyn Local Signing"
set -euo pipefail

NAME="${MERLYN_SIGN_IDENTITY:-Merlyn Local Signing}"
KEYCHAIN="${MERLYN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "✔ Signing identity '$NAME' already exists — nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# `extendedKeyUsage = codeSigning` is what makes `security find-identity -p
# codesigning` match it. 1.2.840.113635.100.6.1.14 is Apple's code-signing
# certificate extension — Certificate Assistant's "Code Signing" template sets it,
# and codesign wants it present on a leaf it is asked to sign with.
cat > "$TMP/openssl.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions    = codesign
prompt             = no
[ dn ]
CN = ${NAME}
[ codesign ]
basicConstraints  = critical,CA:false
keyUsage          = critical,digitalSignature
extendedKeyUsage  = critical,codeSigning
1.2.840.113635.100.6.1.14 = critical,DER:0500
CNF

# /usr/bin/openssl (LibreSSL), not whatever is first on PATH. Homebrew's OpenSSL 3
# writes PKCS#12 with an AES/SHA-256 MAC that macOS's `security import` rejects
# outright ("MAC verification failed"); LibreSSL's default output is exactly what
# the system keychain expects.
SSL=/usr/bin/openssl
P12PASS=merlyn-import   # throwaway: the bundle exists for the length of this script

"$SSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -config "$TMP/openssl.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

"$SSL" pkcs12 -export -out "$TMP/id.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -passout "pass:$P12PASS"

# -T /usr/bin/codesign pre-authorises codesign against the private key, so signing
# doesn't stop for a Keychain prompt on every build.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign -T /usr/bin/security

# Trust it for code signing, so `security find-identity -v -p codesigning` reports
# it as valid rather than CSSMERR_TP_NOT_TRUSTED. `trustRoot`, not `trustAsRoot` —
# the certificate IS its own root, and `trustAsRoot` is rejected outright
# ("SecTrustSettingsSetTrustSettings: One or more parameters ... were not valid").
#
# This puts up one password dialog ("You are making changes to your Certificate
# Trust Settings"). It writes the *user's* trust settings only — no admin domain,
# nothing system-wide.
echo "▶ Trusting the certificate for code signing."
echo "  macOS will ask for your login password once."
if ! security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"; then
  echo
  echo "✖ The certificate was created but NOT trusted. Signing still works — the"
  echo "  identity just won't chain to an anchor. Re-run this script to try again."
  exit 1
fi

echo "✔ Created and trusted signing identity '$NAME'."
echo "  Merlyn now keeps one stable code identity across rebuilds, so the Keychain"
echo "  stops re-asking after every build."
echo
echo "  The identity changed, so the FIRST build after this asks once for Keychain"
echo "  access to the signing key — choose Always Allow."
