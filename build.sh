#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
rm -rf 'build/豆包语音切换.app'
mkdir -p 'build/豆包语音切换.app/Contents/MacOS'
cp Info.plist 'build/豆包语音切换.app/Contents/Info.plist'
clang++ -std=c++17 -O2 -fobjc-arc -Wall -Wextra -arch arm64 -arch x86_64 main.mm \
  -framework AppKit -framework Carbon -framework ApplicationServices \
  -o 'build/豆包语音切换.app/Contents/MacOS/DoubaoVoiceSwitcher'
# Apple Silicon 链接器会自动写入临时签名；Release 必须完全不带签名。
codesign --remove-signature 'build/豆包语音切换.app'
print '已构建未签名应用：build/豆包语音切换.app'
