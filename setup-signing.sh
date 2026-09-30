#!/bin/zsh
set -euo pipefail
sign_dir="$HOME/Library/Application Support/DoubaoVoiceSwitcher"
keychain="$sign_dir/signing.keychain-db"
identity='Doubao Voice Switcher Local Signing'
mkdir -p "$sign_dir"
chmod 700 "$sign_dir"
if [[ -f "$keychain" ]]; then
  if security find-identity -v -p codesigning "$keychain" | /usr/bin/grep -q '"Doubao Voice Switcher Local Signing"'; then
    print '本机固定签名身份已存在。'
    exit 0
  fi
  print -u2 '签名钥匙串已存在但找不到有效身份，请检查钥匙串。'
  exit 1
fi
umask 077
/usr/bin/openssl rand -hex 32 > "$sign_dir/keychain-password"
signing_password=$(cat "$sign_dir/keychain-password")
/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$sign_dir/signing-key.pem" -out "$sign_dir/signing-cert.pem" \
  -subj "/CN=$identity" \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,digitalSignature,keyCertSign' \
  -addext 'extendedKeyUsage=codeSigning' 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$sign_dir/signing-key.pem" \
  -in "$sign_dir/signing-cert.pem" -out "$sign_dir/signing-identity.p12" \
  -passout "pass:$signing_password"
security create-keychain -p "$signing_password" "$keychain"
security unlock-keychain -p "$signing_password" "$keychain"
security import "$sign_dir/signing-identity.p12" -k "$keychain" \
  -P "$signing_password" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$signing_password" "$keychain" >/dev/null
security add-trusted-cert -d -r trustRoot -p codeSign -k "$keychain" \
  "$sign_dir/signing-cert.pem" >/dev/null
print "已创建本机固定签名身份：$identity"
