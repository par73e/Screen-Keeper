import SwiftUI
import AppKit

/// 苹果风紧凑 Liquid Glass 面板（macOS 26+，运行于 NSGlassEffectView 玻璃窗口内）：
/// - 空间绝对锁定：无指针跟随位移与 .interactive() 弹性晃动，鼠标移动时所有元素原地不动
/// - 苹果 Control Center 级「由暗变点亮」悬停光学反馈：顶部三档模式按钮与中部合盖卡片悬停时由暗变亮，无跳动/位移
/// - 纯正层级：外层由原生 NSGlassEffectView 提供实时背景折射与镜面边缘，内部采用克制的半透明模块面与发光徽章，避免玻璃叠玻璃浑浊
struct MenuPanel: View {
    @ObservedObject var store: PowerStore
    @Environment(\.colorScheme) private var scheme

    private let rowShape = RoundedRectangle(cornerRadius: 11, style: .continuous)
    private let cardShape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            modeSection
            if let error = store.assertionError {
                Text(error)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.orange)
            }
            scheduleSection
            clamshellSection
            optionsSection
            holdersSection
            footer
        }
        .padding(11)
        .frame(width: 296)
        .animation(.smooth(duration: 0.22), value: store.mode)
        .onAppear {
            store.refreshHolders()
            store.startHoldersAutoRefresh()
        }
        .onDisappear {
            store.stopHoldersAutoRefresh()
        }
    }

    private var modeAccentColor: Color {
        switch store.mode {
        case .systemAwake: return .green
        case .displayAwake: return .orange
        case .off: return .secondary
        }
    }

    // MARK: - 顶部：图标 / 名称 / 电源状态 / 剩余时间（固定几何槽位，秒级倒计时不抖动）

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        store.mode != .off
                        ? modeAccentColor.opacity(scheme == .dark ? 0.24 : 0.18)
                        : Color.black.opacity(scheme == .dark ? 0.12 : 0.04)
                    )
                Image(nsImage: MenuBarIcon.image(for: store.iconState,
                                                 dark: scheme == .dark,
                                                 level: store.waterLevel))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 17, height: 14)
            }
            .frame(width: 28, height: 28)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        .white.opacity(scheme == .dark ? 0.24 : 0.68),
                        lineWidth: 0.65
                    )
            )

            VStack(alignment: .leading, spacing: 1) {
                Text("Screen Keeper")
                    .font(.system(size: 12.5, weight: .semibold))
                HStack(spacing: 4) {
                    Circle()
                        .fill(powerDotColor)
                        .frame(width: 5, height: 5)
                    Text(store.powerSummary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Group {
                if store.mode != .off {
                    if store.durationChoice == 0 {
                        Text("∞")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(modeAccentColor.opacity(0.90)))
                    } else {
                        Text(store.remainingText)
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .frame(width: 72)
                            .background(Capsule().fill(modeAccentColor.opacity(0.90)))
                    }
                } else {
                    Color.clear
                }
            }
            .frame(width: 72, height: 20, alignment: .trailing)
        }
        .padding(.horizontal, 2)
    }

    private var powerDotColor: Color {
        if store.powerSummary.contains("离线") { return .secondary }
        return store.onACPower ? .green : .orange
    }

    // MARK: - 顶部三档模式（独立控制中心模块 + 悬停由暗变点亮，原地固定）

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            modeRow(.systemAwake,
                    icon: "bolt.fill",
                    title: "保持系统唤醒",
                    subtitle: "后台不中断，屏幕可熄灭")
            modeRow(.displayAwake,
                    icon: "sun.max.fill",
                    title: "屏幕也保持常亮",
                    subtitle: "保持常亮，注意耗电")
            modeRow(.off,
                    icon: "power",
                    title: "关闭",
                    subtitle: "恢复默认睡眠")
        }
    }

    private func modeRow(_ m: KeepAwakeMode,
                         icon: String,
                         title: String,
                         subtitle: String) -> some View {
        let selected = (store.mode == m)
        let accent: Color? = {
            switch m {
            case .systemAwake: return .green
            case .displayAwake: return .orange
            case .off: return nil
            }
        }()
        let tint: Color? = selected ? accent : nil

        return ModeRowButton(
            icon: icon,
            title: title,
            subtitle: subtitle,
            selected: selected,
            accentColor: accent,
            tint: tint,
            shape: rowShape
        ) {
            if m == .off { store.deactivate() } else { store.activate(m) }
        }
    }

    // MARK: - 定时自动关闭（静止分组面）

    private var scheduleSection: some View {
        GroupedSurface(shape: cardShape) {
            VStack(alignment: .leading, spacing: 5) {
                Text("自动关闭")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("", selection: $store.durationChoice) {
                    Text("1小时").tag(TimeInterval(1 * 3600))
                    Text("2小时").tag(TimeInterval(2 * 3600))
                    Text("4小时").tag(TimeInterval(4 * 3600))
                    Text("8小时").tag(TimeInterval(8 * 3600))
                    Text("不限").tag(TimeInterval(0))
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                Text(scheduleHint)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var scheduleHint: String {
        guard store.mode != .off else { return "按此时长自动关闭" }
        if store.deadline == nil { return "持续生效至手动关闭" }
        return "到期自动恢复"
    }

    // MARK: - 常规选项（默认收起，位于合盖运行下方，点击整行展开/收起）

    private var optionsSection: some View {
        OptionsAccordion(store: store, shape: cardShape)
    }

    // MARK: - 合盖保持运行（液态玻璃卡片，整卡可点击，悬停由暗变点亮，原地固定）

    private var hasClamshellExtras: Bool {
        store.clamshellConfirmNeeded || store.clamshellLeftover || store.clamshellOn || store.clamshellError != nil
    }

    private var clamshellLocked: Bool {
        store.mode == .off && !store.clamshellOn
    }

    private var clamshellControlsBusy: Bool {
        store.clamshellBusy || store.clamshellPasswordlessBusy
    }

    private func toggleClamshell() {
        guard !clamshellControlsBusy, !clamshellLocked else { return }
        if store.clamshellOn {
            store.setClamshellEnabled(false)
        } else if store.clamshellConfirmNeeded {
            store.cancelClamshellConfirm()
        } else {
            store.requestClamshellEnable()
        }
    }

    private var clamshellSection: some View {
        LuminousGlassTile(shape: cardShape,
                          tint: store.clamshellOn ? .orange : nil,
                          isSelected: store.clamshellOn,
                          isEnabled: !clamshellLocked) { hovered in
            VStack(alignment: .leading, spacing: 6) {
                Button(action: toggleClamshell) {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(clamshellBadgeFill(hovered: hovered))
                            Image(systemName: "laptopcomputer")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(store.clamshellOn ? .white : (hovered && !clamshellLocked ? .primary : .secondary))
                        }
                        .frame(width: 24, height: 24)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("合盖保持运行")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(clamshellLocked ? .secondary : .primary)
                            Text(clamshellLocked ? "需先开启唤醒模式" : "合盖不睡眠，开盖自动恢复")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)

                        if store.clamshellBusy {
                            ProgressView().controlSize(.mini)
                        }
                        Toggle("", isOn: .constant(store.clamshellOn))
                            .labelsHidden()
                            .controlSize(.mini)
                            .disabled(clamshellControlsBusy || clamshellLocked)
                            .allowsHitTesting(false)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(clamshellControlsBusy || clamshellLocked)
                .opacity(clamshellLocked ? 0.58 : 1)

                if hasClamshellExtras {
                    VStack(alignment: .leading, spacing: 6) {
                        if store.clamshellConfirmNeeded {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("⚠️ 合盖后不会睡眠，注意散热与耗电。3 秒后降亮度至 10%，开盖自动恢复。")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.orange)
                                HStack(spacing: 6) {
                                    Button("仍要开启") { store.confirmClamshellEnable() }
                                        .disabled(clamshellControlsBusy)
                                        .buttonStyle(AppleGlassButtonStyle(tint: .orange, prominent: true, compact: true))
                                    Button("取消") { store.cancelClamshellConfirm() }
                                        .buttonStyle(AppleGlassButtonStyle(compact: true))
                                }
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.orange.opacity(scheme == .dark ? 0.14 : 0.10))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.orange.opacity(0.32), lineWidth: 0.75)
                            )
                        }

                        if store.clamshellLeftover {
                            HStack(spacing: 6) {
                                Text(store.clamshellOn ? "系统仍处于「合盖不睡眠」" : "系统睡眠状态尚未确认")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.red)
                                Spacer()
                                Button("恢复") { store.setClamshellEnabled(false) }
                                    .disabled(clamshellControlsBusy)
                                    .buttonStyle(AppleGlassButtonStyle(compact: true))
                            }
                        }

                        if store.clamshellOn && !store.clamshellLeftover {
                            HStack(spacing: 6) {
                                if let sec = store.clamshellDimCountdown {
                                    Text("已开启 · \(sec) 秒后亮度降至 10%")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.orange)
                                } else {
                                    Text("合盖不睡眠运行中 · 开盖自动恢复")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.red)
                                }
                                Spacer()
                                Button("立即恢复") { store.setClamshellEnabled(false) }
                                    .disabled(clamshellControlsBusy)
                                    .buttonStyle(AppleGlassButtonStyle(compact: true))
                            }
                        }

                        if let err = store.clamshellError {
                            Text("操作未完成：\(err)")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.bottom, 7)
                }
            }
        }
    }

    private func clamshellBadgeFill(hovered: Bool) -> Color {
        if store.clamshellOn { return .orange }
        if hovered {
            return Color.primary.opacity(scheme == .dark ? 0.16 : 0.10)
        }
        return Color.primary.opacity(scheme == .dark ? 0.08 : 0.06)
    }

    // MARK: - 谁在阻止睡眠（默认收起，点击整行可展开/收起）

    private var holdersSection: some View {
        HoldersAccordion(store: store, shape: cardShape)
    }

    // MARK: - 底部（原地固定，退出按钮无晃动）

    private var footer: some View {
        HStack {
            Text("退出即失效")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("退出") { NSApplication.shared.terminate(nil) }
                .buttonStyle(AppleGlassButtonStyle(compact: true))
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - 苹果 Control Center 级「由暗变点亮」液态玻璃组件

/// 顶部的三档模式按钮：完全独立的本地 hover 状态，严格锁定位置，悬停时玻璃表面与图标徽章同步点亮。
private struct ModeRowButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let selected: Bool
    let accentColor: Color?
    let tint: Color?
    let shape: RoundedRectangle
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            LuminousGlassTile(shape: shape, tint: tint, isSelected: selected) { hovered in
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(badgeFill(hovered: hovered))
                            .overlay(
                                Circle()
                                    .strokeBorder(.white.opacity(badgeRimOpacity(hovered: hovered)), lineWidth: 0.65)
                            )
                        Image(systemName: icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(iconColor(hovered: hovered))
                    }
                    .frame(width: 24, height: 24)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Color.primary.opacity(hovered || selected ? 0.72 : 0.54))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(accentColor ?? Color.primary.opacity(0.80))
                        .opacity(selected ? 1 : 0)
                        .frame(width: 14)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(shape)
            }
        }
        .buttonStyle(.plain)
    }

    private func badgeFill(hovered: Bool) -> Color {
        if selected, let accentColor {
            return hovered ? accentColor.opacity(0.92) : accentColor
        }
        if selected {
            return Color.primary.opacity(scheme == .dark ? 0.28 : 0.16)
        }
        if hovered {
            return Color.primary.opacity(scheme == .dark ? 0.18 : 0.11)
        }
        return Color.primary.opacity(scheme == .dark ? 0.08 : 0.05)
    }

    private func badgeRimOpacity(hovered: Bool) -> Double {
        if selected || hovered { return scheme == .dark ? 0.34 : 0.55 }
        return scheme == .dark ? 0.10 : 0.20
    }

    private func iconColor(hovered: Bool) -> Color {
        if selected && accentColor != nil { return .white }
        if selected || hovered { return .primary }
        return .secondary
    }
}

private final class HoverModel: ObservableObject {
    @Published var isHovered = false
}

private final class ExpansionModel: ObservableObject {
    @Published var isExpanded = false
}

/// 可折叠的「常规选项」分组：默认收起，内部开关右对齐。
private struct OptionsAccordion: View {
    @ObservedObject var store: PowerStore
    let shape: RoundedRectangle

    @StateObject private var expansion = ExpansionModel()
    @Environment(\.colorScheme) private var scheme

    private var enabledCount: Int {
        [
            store.autoOffOnUnplug,
            store.restoreOnLaunch,
            store.loginItemEnabled,
            store.clamshellPasswordless,
        ].filter { $0 }.count
    }

    var body: some View {
        GroupedSurface(shape: shape) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    expansion.isExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expansion.isExpanded ? 90 : 0))
                            .frame(width: 12, height: 12)

                        Text("常规选项")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)

                        Text("\(enabledCount)/4")
                            .font(.system(size: 9.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Color.primary.opacity(0.65))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.10 : 0.06))
                            )

                        Spacer(minLength: 4)
                    }
                    .frame(height: 18)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expansion.isExpanded {
                    Divider().opacity(0.35)
                    VStack(alignment: .leading, spacing: 5.5) {
                        optionRow(isOn: $store.autoOffOnUnplug,
                                  title: "拔电源自动关闭",
                                  subtitle: "用电池时自动关闭")
                        Divider().opacity(0.35)
                        optionRow(isOn: $store.restoreOnLaunch,
                                  title: "启动时恢复上次模式",
                                  subtitle: "重启后恢复未过期模式")
                        Divider().opacity(0.35)
                        optionRow(isOn: Binding(get: { store.loginItemEnabled },
                                                set: { store.setLoginItem($0) }),
                                  title: "开机自启",
                                  subtitle: "登录时自动启动")
                        Divider().opacity(0.35)
                        optionRow(isOn: Binding(get: { store.clamshellPasswordless },
                                                set: { store.setClamshellPasswordless($0) }),
                                  title: "合盖模式免密",
                                  subtitle: store.clamshellPasswordless ? "已授权，免密开关" : "授权一次，后续免密")
                            .disabled(store.clamshellPasswordlessBusy || store.clamshellBusy)
                    }
                }
            }
        }
    }

    private func optionRow(isOn: Binding<Bool>, title: String, subtitle: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11.5))
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}

/// 可折叠的「谁在阻止睡眠」分组：默认收起以保持面板紧凑，点击整行平滑展开或收起。
private struct HoldersAccordion: View {
    @ObservedObject var store: PowerStore
    let shape: RoundedRectangle

    @StateObject private var expansion = ExpansionModel()
    @Environment(\.colorScheme) private var scheme

    private var uniqueHolderCount: Int {
        Set(store.holders.map { "\($0.process)|\($0.assertion)" }).count
    }

    var body: some View {
        GroupedSurface(shape: shape) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        expansion.isExpanded.toggle()
                        if expansion.isExpanded {
                            store.refreshHolders()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(expansion.isExpanded ? 90 : 0))
                                .frame(width: 12, height: 12)

                            Text("谁在阻止睡眠")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)

                            Text(uniqueHolderCount > 0 ? "\(uniqueHolderCount)" : "无")
                                .font(.system(size: 9.5, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(Color.primary.opacity(uniqueHolderCount > 0 ? 0.75 : 0.38))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.10 : 0.06))
                                )

                            Spacer(minLength: 4)
                        }
                        .frame(height: 18)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    AppleGlassIconButton(systemName: "arrow.clockwise") {
                        store.refreshHolders()
                    }
                    .opacity(expansion.isExpanded ? 1 : 0)
                    .allowsHitTesting(expansion.isExpanded)
                }
                .frame(height: 18)

                if expansion.isExpanded {
                    Divider().opacity(0.35)
                    Text(store.holdersSummaryText)
                        .font(.system(size: 10))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(5)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }
}

/// 核心光学悬停容器（嵌于清透 NSGlassEffectView 内）：
/// - 未悬停且未选中时呈现极轻透的半透明底色与清晰高光边；悬停时渐显苹果 Control Center 式顶光漫反射与高光描边（"由暗变点亮"）
/// - 无色选中态（如「关闭」）带独立卡片衬底与鲜明边缘，避免融入背景；零 offset / 零 scale，100% 原地固定
private struct LuminousGlassTile<ShapeType: InsettableShape, Content: View>: View {
    let shape: ShapeType
    let tint: Color?
    let isSelected: Bool
    let isEnabled: Bool
    let content: (Bool) -> Content

    @StateObject private var hover = HoverModel()
    @Environment(\.colorScheme) private var scheme

    init(shape: ShapeType,
         tint: Color? = nil,
         isSelected: Bool = false,
         isEnabled: Bool = true,
         @ViewBuilder content: @escaping (Bool) -> Content) {
        self.shape = shape
        self.tint = tint
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.content = content
    }

    private var activeHover: Bool {
        isEnabled && hover.isHovered
    }

    var body: some View {
        content(activeHover)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    if let tint, isSelected {
                        shape.fill(tint.opacity(scheme == .dark ? 0.22 : 0.17))
                    } else if isSelected {
                        shape.fill(Color.primary.opacity(scheme == .dark ? 0.14 : 0.085))
                    } else {
                        shape.fill(Color.black.opacity(restingDimOpacity))
                    }

                    shape.fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(topSheenOpacity),
                                .white.opacity(bottomSheenOpacity)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(topBorderOpacity),
                            .white.opacity(bottomBorderOpacity)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: (activeHover || isSelected) ? 0.85 : 0.6
                )
                .allowsHitTesting(false)
            }
            .contentShape(shape)
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.16)) {
                    hover.isHovered = inside
                }
            }
    }

    private var restingDimOpacity: Double {
        if activeHover || isSelected { return 0 }
        return scheme == .dark ? 0.18 : 0.05
    }

    private var topSheenOpacity: Double {
        if activeHover {
            return scheme == .dark ? 0.18 : 0.46
        }
        if isSelected {
            return scheme == .dark ? 0.09 : 0.28
        }
        return 0
    }

    private var bottomSheenOpacity: Double {
        if activeHover {
            return scheme == .dark ? 0.05 : 0.14
        }
        if isSelected {
            return scheme == .dark ? 0.02 : 0.08
        }
        return 0
    }

    private var topBorderOpacity: Double {
        if activeHover {
            return scheme == .dark ? 0.50 : 0.90
        }
        if isSelected {
            return scheme == .dark ? 0.40 : 0.82
        }
        return scheme == .dark ? 0.15 : 0.42
    }

    private var bottomBorderOpacity: Double {
        if activeHover {
            return scheme == .dark ? 0.16 : 0.36
        }
        if isSelected {
            return scheme == .dark ? 0.14 : 0.30
        }
        return scheme == .dark ? 0.04 : 0.16
    }
}

/// 静态分组容器（用于定时、开关选项、阻止睡眠列表）：
/// 保持清透玻璃穿透过底感，仅用极轻内衬与细高光边区分层级，鼠标经过时纹丝不动。
private struct GroupedSurface<ShapeType: InsettableShape, Content: View>: View {
    let shape: ShapeType
    let content: Content
    @Environment(\.colorScheme) private var scheme

    init(shape: ShapeType, @ViewBuilder content: () -> Content) {
        self.shape = shape
        self.content = content()
    }

    var body: some View {
        content
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                shape.fill(Color.black.opacity(scheme == .dark ? 0.15 : 0.04))
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(scheme == .dark ? 0.16 : 0.52),
                            .white.opacity(scheme == .dark ? 0.04 : 0.16)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.6
                )
                .allowsHitTesting(false)
            )
    }
}

/// 静止控制中心胶囊按钮样式：
/// 嵌入在 NSGlassEffectView 内，悬停时原地微微点亮，按下时轻微反馈，绝不左右晃动。
private struct AppleGlassButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var prominent: Bool = false
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        AppleGlassButtonBody(
            configuration: configuration,
            tint: tint,
            prominent: prominent,
            compact: compact
        )
    }

    private struct AppleGlassButtonBody: View {
        let configuration: Configuration
        let tint: Color?
        let prominent: Bool
        let compact: Bool

        @StateObject private var hover = HoverModel()
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 10 : 11, weight: .medium))
                .foregroundStyle(prominent ? .white : .primary)
                .padding(.horizontal, compact ? 8 : 10)
                .padding(.vertical, compact ? 3 : 4)
                .background {
                    ZStack {
                        if prominent, let tint {
                            Capsule().fill(tint.opacity(hover.isHovered ? 0.95 : 0.82))
                        } else {
                            Capsule().fill(Color.black.opacity(hover.isHovered ? 0 : (scheme == .dark ? 0.20 : 0.055)))
                        }
                        if hover.isHovered {
                            Capsule().fill(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(prominent ? 0.22 : (scheme == .dark ? 0.18 : 0.52)),
                                        .white.opacity(prominent ? 0.06 : (scheme == .dark ? 0.06 : 0.18))
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        }
                        if configuration.isPressed {
                            Capsule().fill(Color.black.opacity(0.16))
                        }
                    }
                }
                .overlay(
                    Capsule()
                        .strokeBorder(
                            .white.opacity(hover.isHovered ? (scheme == .dark ? 0.45 : 0.85) : (scheme == .dark ? 0.14 : 0.36)),
                            lineWidth: hover.isHovered ? 0.75 : 0.5
                        )
                        .allowsHitTesting(false)
                )
                .contentShape(Capsule())
                .onHover { inside in
                    withAnimation(.easeOut(duration: 0.15)) {
                        hover.isHovered = inside
                    }
                }
        }
    }
}

/// 静态圆形图标按钮（刷新等小图标），原地微微点亮，无晃动
private struct AppleGlassIconButton: View {
    let systemName: String
    let action: () -> Void

    @StateObject private var hover = HoverModel()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(hover.isHovered ? .primary : .secondary)
                .frame(width: 18, height: 18)
                .background(
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(hover.isHovered ? 0 : (scheme == .dark ? 0.18 : 0.05)))
                        Circle()
                            .fill(Color.white.opacity(hover.isHovered ? (scheme == .dark ? 0.16 : 0.48) : 0))
                    }
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            .white.opacity(hover.isHovered ? (scheme == .dark ? 0.42 : 0.82) : (scheme == .dark ? 0.12 : 0.32)),
                            lineWidth: 0.6
                        )
                        .allowsHitTesting(false)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) {
                hover.isHovered = inside
            }
        }
    }
}
