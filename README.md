# 豆包语音切换

一个 macOS 菜单栏小工具，让你平时使用原来的输入法，需要语音时临时切到豆包输入法。

- **按住 Fn + Control**：开始语音；松开后等待豆包提交文字，再恢复原输入法。
- **点按右 Option**：开始语音；再点按一次停止，然后恢复原输入法。
- **单按 Fn**：在系统简体拼音或双拼与 ABC 或 U.S. 英文之间切换，可在菜单栏关闭。若同时启用多种同语言输入法，会记住最近使用的那一种。

程序只监听快捷键，不读取普通打字内容。当前版本的豆包语音快捷键固定按 **Fn + Control** 和**右 Option** 处理；右 Option 功能还依赖 macOS 的“选择输入法菜单中的下一个输入法”快捷键（默认 Control + Option + 空格）。启动语音时可能会短暂切换并恢复当前应用焦点，以便豆包接收快捷键。

菜单栏图标平时隐藏，启动语音时显示；停止语音 10 秒后自动隐藏。需要调整恢复延迟或 Fn 功能时，可在图标显示期间打开菜单。若键盘监听未获权限，图标会保留以显示错误并提供重试入口。

## 请 Agent 帮你安装

把这个链接发给你的 Agent，让它照说明在**你的 Mac 本地**完成下载、签名和安装：

**[AGENTS.md：安装与本地签名指南](https://github.com/yxzlwz/doubao-voice-switcher/blob/main/AGENTS.md)**

Agent 应先问你是否改过豆包默认的语音输入快捷键。安装时会在本机创建签名身份；签名私钥不会上传到 GitHub。系统要求的“辅助功能”和“输入监控”权限仍需你亲自在系统设置中授予。

## 下载与源码

[Releases](https://github.com/yxzlwz/doubao-voice-switcher/releases) 提供同时支持 Apple Silicon 和 Intel 的**未签名** macOS 应用压缩包，下载后需在本机签名才能安装使用。源码也可在本机执行 `./install.sh` 构建、签名并安装。卸载时运行 `./uninstall.sh`。

本项目使用固定的豆包输入法 ID `com.bytedance.inputmethod.doubaoime.pinyin`。实际按键响应仍取决于豆包输入法版本与快捷键设置。
