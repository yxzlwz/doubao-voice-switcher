#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
app_path="${1:-build/豆包语音切换.app}"
if [[ ! -d "$app_path/Contents/MacOS" ]]; then
  print -u2 "找不到应用包：$app_path"
  exit 1
fi
sign_dir="$HOME/Library/Application Support/DoubaoVoiceSwitcher"
if [[ ! -f "$sign_dir/signing.keychain-db" ]]; then
  ./setup-signing.sh
fi
signing_password=$(cat "$sign_dir/keychain-password")
security unlock-keychain -p "$signing_password" "$sign_dir/signing.keychain-db"
codesign --force --sign 'Doubao Voice Switcher Local Signing' \
  --keychain "$sign_dir/signing.keychain-db" \
  --identifier local.doubao.voice.switcher "$app_path" >/dev/null
codesign --verify --strict "$app_path"
print "已使用本机身份签名：$app_path"
