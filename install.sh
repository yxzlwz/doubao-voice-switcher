#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
if [[ $# -eq 0 ]]; then
  ./build.sh
  source_app='build/豆包语音切换.app'
elif [[ $# -eq 2 && "$1" == '--app' ]]; then
  source_app="$2"
else
  print -u2 '用法：./install.sh [--app /path/to/豆包语音切换.app]'
  exit 2
fi
./sign-local.sh "$source_app"
app_dir="$HOME/Applications/豆包语音切换.app"
agent_file="$HOME/Library/LaunchAgents/local.doubao.voice.switcher.plist"
agent_id='local.doubao.voice.switcher'
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
launchctl bootout "gui/$(id -u)/$agent_id" 2>/dev/null || true
for app_pid in $(pgrep -x DoubaoVoiceSwitcher 2>/dev/null || true); do
  running_command=$(ps -p "$app_pid" -o command= 2>/dev/null || true)
  if [[ "$running_command" == "$app_dir/Contents/MacOS/DoubaoVoiceSwitcher"* ]]; then
    kill "$app_pid"
  fi
done
for attempt in {1..20}; do
  if ! pgrep -f "$app_dir/Contents/MacOS/DoubaoVoiceSwitcher" >/dev/null 2>&1; then break; fi
  sleep 0.2
done
if pgrep -f "$app_dir/Contents/MacOS/DoubaoVoiceSwitcher" >/dev/null 2>&1; then
  print -u2 '旧版本仍在运行，无法安全更新应用。'
  exit 1
fi
/usr/bin/ditto "$source_app" "$app_dir"
cat > "$agent_file" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$agent_id</string>
<key>ProgramArguments</key><array>
<string>/usr/bin/open</string><string>-g</string><string>-a</string><string>$app_dir</string>
</array>
<key>RunAtLoad</key><true/>
<key>LimitLoadToSessionType</key><string>Aqua</string>
<key>StandardOutPath</key><string>$HOME/Library/Logs/DoubaoVoiceSwitcher.log</string>
<key>StandardErrorPath</key><string>$HOME/Library/Logs/DoubaoVoiceSwitcher.log</string>
</dict></plist>
PLIST
if ! launchctl bootstrap "gui/$(id -u)" "$agent_file"; then
  sleep 1
  launchctl bootstrap "gui/$(id -u)" "$agent_file"
fi
print "已安装并启动：$app_dir"
print '请在菜单栏找到圆形语音图标；首次使用请检查“输入监控”和“辅助功能”两项权限；程序不会自动重复弹窗。'
print '要让单按 Fn 仅切系统中英文，请手动将系统“按下 Fn 键时”设为“不执行任何操作”。'
