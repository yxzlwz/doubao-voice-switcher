#!/bin/zsh
set -euo pipefail
agent_id='local.doubao.voice.switcher'
app_dir="$HOME/Applications/豆包语音切换.app"
launchctl bootout "gui/$(id -u)/$agent_id" 2>/dev/null || true
for app_pid in $(pgrep -x DoubaoVoiceSwitcher 2>/dev/null || true); do
  running_command=$(ps -p "$app_pid" -o command= 2>/dev/null || true)
  if [[ "$running_command" == "$app_dir/Contents/MacOS/DoubaoVoiceSwitcher"* ]]; then
    kill "$app_pid"
  fi
done
rm -f "$HOME/Library/LaunchAgents/$agent_id.plist"
rm -rf "$app_dir"
print '已移除登录项和应用。系统隐私权限可在“系统设置”中单独移除。'
