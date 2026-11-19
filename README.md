# Screen Keeper (`ScreenMaintainer`)

一个为 macOS 26+ 打造的极简菜单栏防休眠工具（Liquid Glass 风格），让 Agent、下载、编译等后台任务不被系统睡眠打断，同时透明展示当前阻止系统睡眠的电源断言。

无 Dock 图标、无主窗口，常驻菜单栏。

## 核心特性

- **三档电源控制**
  - **保持系统唤醒**：创建 `PreventUserIdleSystemSleep` 断言，后台任务不断线，屏幕仍可正常熄灭省电。
  - **屏幕也保持常亮**：创建 `PreventUserIdleDisplaySleep` 断言，适合盯进度与演示场景。
  - **关闭**：释放全部断言，恢复系统默认睡眠策略。
- **定时自动关闭**：支持 `1小时` / `2小时` / `4小时` / `8小时` / `不限`，菜单栏图标采用「水位」样式实时反映剩余时长。
- **合盖保持运行（带安全护栏与亮度自动化）**
  - 通过系统级 `pmset -a disablesleep` 拦截合盖睡眠信号，开启前提供风险二次确认。
  - 授权开启 **3 秒后**自动将内置屏幕亮度降至 **10%** 以减少发热与耗电。
  - 下次**开盖时**自动平滑抬回原亮度，并自动关闭「合盖保持运行」。
  - 支持在「常规选项」中一键开启**合盖模式免密**（写入 `/etc/sudoers.d/screenmaintainer` 精确白名单，仅放行 `pmset -a disablesleep 0/1`，重启 Mac 后依然持久生效）。
- **常规选项（默认收起）**
  - 拔电源自动关闭
  - 启动时恢复上次模式（未过期时）
  - 开机自启（`SMAppService` 登录项）
  - 合盖模式免密
- **谁在阻止睡眠（默认收起）**：实时解析 `pmset -g assertions`，一键展开查看当前阻止系统睡眠的进程。
- **原生 Liquid Glass 体验**：基于 `NSStatusItem` + 无边框 `NSPanel` + 原生 `NSGlassEffectView` 构建，居中对齐菜单栏图标展开，悬停呈现苹果控制中心式「由暗变点亮」光学反馈。

## 安装与运行

### 方式一：直接下载 Release
从本仓库 [Releases](https://github.com/par73e/Screen-Keeper/releases) 下载 `ScreenMaintainer.app.zip`，解压后将 `ScreenMaintainer.app` 拖入 `/Applications/` 即可运行。

> 若首次打开遇到 macOS 未签名提示，可执行：`xattr -cr /Applications/ScreenMaintainer.app` 后再打开。

### 方式二：源码构建（仅需 Xcode Command Line Tools）

```bash
./build-app.sh          # 编译并生成 build/ScreenMaintainer.app
open build/ScreenMaintainer.app

# 安装到应用程序目录
cp -R build/ScreenMaintainer.app /Applications/
open /Applications/ScreenMaintainer.app
```

## 系统要求

- macOS 26.0 或更高版本（Apple Silicon / Intel）

## CLI 调试参数

```bash
ScreenMaintainer --dump-assertions                  # 打印当前阻止睡眠的进程列表后退出
ScreenMaintainer --activate systemAwake --seconds 60  # 以指定模式启动 60 秒（测试用）
```

## 故障排查与卸载

若异常退出导致系统残留 `SleepDisabled 1`，重新打开 App 会尝试恢复由本 App 开启的合盖模式。需要管理员授权或无法判断设置来源时，可在面板中点「恢复」，也可手动执行：

```bash
sudo pmset -a disablesleep 0
```

如需完整卸载：
1. 在面板中关闭「开机自启」与「合盖模式免密」（或手动删除 `/etc/sudoers.d/screenmaintainer`），退出 App；
2. 删除 `/Applications/ScreenMaintainer.app`；
3. （可选）清理偏好设置：`defaults delete com.suep.screenmaintainer`。

## License

本项目采用 [MIT License](LICENSE) 开源。
