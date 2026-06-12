#!/usr/bin/env swift
//
// vidpaper.swift — single-file per-screen mp4 video wallpaper for macOS.
//   chmod +x vidpaper.swift && ./vidpaper.swift &
//

import AppKit
import AVFoundation
import Foundation

// MARK: - Localization

enum Lang: String, Codable { case zh, en }

struct L {
    static var lang: Lang = .en

    static var selectWallpaper: String { lang == .zh ? "选择壁纸…" : "Select Wallpaper…" }
    static var pause: String           { lang == .zh ? "暂停" : "Pause" }
    static var resume: String          { lang == .zh ? "继续" : "Resume" }
    static var stop: String            { lang == .zh ? "停止" : "Stop" }
    static var restore: String         { lang == .zh ? "恢复" : "Restore" }
    static var quit: String            { lang == .zh ? "退出" : "Quit" }
    static var language: String        { lang == .zh ? "语言" : "Language" }
    static var volume: String          { lang == .zh ? "音量" : "Volume" }
    static var openPanelTitle: String  { lang == .zh ? "选择视频壁纸 (mp4 / mov)" : "Select Video Wallpaper (mp4 / mov)" }
    static var unsupportedFile: String { lang == .zh ? "不支持的文件类型" : "Unsupported file type" }
    static var fileMissing: String     { lang == .zh ? "上次的视频文件已不可用" : "The last wallpaper file is no longer available." }
    static var langZh: String          { "中文" }
    static var langEn: String          { "English" }
}

// MARK: - On-disk paths

private let configDir: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/vidpaper")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()
private let stateURL = configDir.appendingPathComponent("state.json")
private let blackImageURL = configDir.appendingPathComponent("black.png")
private let wallpaperBackupURL = configDir.appendingPathComponent("wallpaper-backup.plist")

// macOS 14+ stores the wallpaper selection here. setDesktopImageURL writes
// into it, so we snapshot before overwriting and copy back at quit.
private let systemWallpaperIndexPlist = FileManager.default
    .homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")

// MARK: - Persisted state

private struct ScreenState: Codable {
    var name: String
    var lastPath: String?
    var volume: Float?
}

private struct PersistedState: Codable {
    var lang: String?
    var screens: [ScreenState]?
}

private func loadState() -> PersistedState {
    guard let data = try? Data(contentsOf: stateURL),
          let state = try? JSONDecoder().decode(PersistedState.self, from: data)
    else { return PersistedState() }
    return state
}

private func saveState(_ state: PersistedState) {
    let enc = JSONEncoder()
    enc.outputFormatting = .prettyPrinted
    do {
        let data = try enc.encode(state)
        try data.write(to: stateURL, options: .atomic)
    } catch {
        FileHandle.standardError.write(Data("vidpaper: saveState failed: \(error)\n".utf8))
    }
}

// MARK: - System wallpaper helpers
//
// Menubar samples the desktop wallpaper, so we keep it black: (a) set the
// system wallpaper to a 2x2 black PNG, and (b) overlay a black CALayer over
// the menubar strip on the main screen (Tahoe 26+).

func ensureBlackImage() {
    if FileManager.default.fileExists(atPath: blackImageURL.path) { return }
    let image = NSImage(size: NSSize(width: 2, height: 2))
    image.lockFocus()
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: 2, height: 2).fill()
    image.unlockFocus()
    if let tiff = image.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiff),
       let png = bitmap.representation(using: .png, properties: [:]) {
        try? png.write(to: blackImageURL)
    }
}

// MUST run before any setDesktopImageURL(black) or the backup is polluted.
// Skip if a backup from a previous unclean quit exists.
func backupSystemWallpaperConfig() {
    let fm = FileManager.default
    guard fm.fileExists(atPath: systemWallpaperIndexPlist.path) else {
        FileHandle.standardError.write(Data("vidpaper: Index.plist not found — restore on quit will fail\n".utf8))
        return
    }
    if fm.fileExists(atPath: wallpaperBackupURL.path) { return }
    do {
        try fm.copyItem(at: systemWallpaperIndexPlist, to: wallpaperBackupURL)
    } catch {
        FileHandle.standardError.write(Data("vidpaper: backup failed: \(error)\n".utf8))
    }
}

// Restore Index.plist from backup + bounce WallpaperAgent. Backup is NOT
// deleted here — it's reused across Stop calls, removed only at quit.
func restoreSystemWallpaper() {
    let fm = FileManager.default
    if fm.fileExists(atPath: wallpaperBackupURL.path) {
        do { try fm.removeItem(at: systemWallpaperIndexPlist) }
        catch let nsErr as NSError where nsErr.code == NSFileNoSuchFileError ||
            (nsErr.domain == NSCocoaErrorDomain && nsErr.code == 4) { /* agent hasn't rebuilt yet — OK */ }
        catch {
            FileHandle.standardError.write(Data("vidpaper: remove Index.plist failed: \(error)\n".utf8))
        }
        do { try fm.copyItem(at: wallpaperBackupURL, to: systemWallpaperIndexPlist) }
        catch {
            FileHandle.standardError.write(Data("vidpaper: restore Index.plist failed: \(error)\n".utf8))
        }
    }
    bounceWallpaperAgent()
}

func cleanupBackup() {
    try? FileManager.default.removeItem(at: wallpaperBackupURL)
}

func bounceWallpaperAgent() {
    let uid = getuid()
    // killall synchronously so they're dead before the process exits.
    for args in [["WallpaperAgent"], ["WallpaperImageExtension"], ["WallpaperAerialsExtension"]] {
        let task = Process()
        task.launchPath = "/usr/bin/killall"
        task.arguments = args
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do { try task.run(); task.waitUntilExit() } catch { /* may already be gone */ }
    }
    let kick = Process()
    kick.launchPath = "/bin/launchctl"
    kick.arguments = ["kickstart", "-k", "gui/\(uid)/com.apple.wallpaper.agent"]
    kick.standardOutput = Pipe()
    kick.standardError = Pipe()
    try? kick.run()
}

// MARK: - Video host view

// Retains the AVPlayerLooper; looper stops looping if deallocated.
final class VideoBackendHostView: NSView {
    var looper: AVPlayerLooper?
}

// MARK: - Window + player setup

// Desktop-level borderless window: sits below user icons, above (lower-level
// than) the system wallpaper. Spans all Spaces; click-through to desktop.
@MainActor
func createWallpaperWindow(screen: NSScreen) -> NSWindow {
    let window = NSWindow(
        contentRect: screen.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false)
    window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.isMovable = false
    window.ignoresMouseEvents = true
    window.backgroundColor = .black
    window.setFrame(screen.frame, display: false)
    return window
}

// AVQueuePlayer + AVPlayerLooper = seamless loop. Looper retained by host view.
@MainActor
func setupVideoContent(window: NSWindow, screen: NSScreen, path: String, volume: Float) -> AVPlayer {
    let url = URL(fileURLWithPath: path)
    let item = AVPlayerItem(url: url)

    let queuePlayer = AVQueuePlayer(playerItem: item)
    queuePlayer.volume = volume
    queuePlayer.actionAtItemEnd = .advance

    let looper = AVPlayerLooper(player: queuePlayer, templateItem: item)

    let playerLayer = AVPlayerLayer(player: queuePlayer)
    playerLayer.videoGravity = .resizeAspectFill
    playerLayer.frame = CGRect(origin: .zero, size: screen.frame.size)

    let host = VideoBackendHostView(frame: CGRect(origin: .zero, size: screen.frame.size))
    host.wantsLayer = true
    host.looper = looper
    host.layer?.addSublayer(playerLayer)
    host.autoresizingMask = [.width, .height]

    // Tahoe 26+ menubar samples below-window pixels — cover the strip on the
    // main screen so it stays black.
    if screen == NSScreen.main {
        let menubarH = NSStatusBar.system.thickness
        let cover = CALayer()
        cover.backgroundColor = NSColor.black.cgColor
        cover.frame = CGRect(
            x: 0,
            y: screen.frame.height - menubarH,
            width: screen.frame.width,
            height: menubarH)
        host.layer?.addSublayer(cover)
    }

    window.contentView = host
    queuePlayer.play()
    return queuePlayer
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!

    // Per-screen state keyed by NSScreen.localizedName (identical models collide).
    private var windows: [String: NSWindow] = [:]
    private var players: [String: AVPlayer] = [:]
    private var activeSources: [String: String] = [:]
    private var lastSources: [String: String] = [:]
    private var pausedScreens: Set<String> = []
    private var volumeByScreen: [String: Float] = [:]

    // Snapshot of user-paused screens before sleep, so wake doesn't auto-resume them.
    private var preSystemPauseSnapshot: Set<String>?

    private let defaultVolume: Float = 1.0
    private let volumeSteps: Int = 5   // 6 ticks: 0/20/40/60/80/100%

    // 0.5s trailing debounce for state.json writes (slider drags burst).
    private var persistTimer: Timer?

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureBlackImage()
        backupSystemWallpaperConfig()

        let state = loadState()
        if let s = state.lang, let l = Lang(rawValue: s) { L.lang = l }
        for sc in state.screens ?? [] {
            if let p = sc.lastPath { lastSources[sc.name] = p }
            if let v = sc.volume { volumeByScreen[sc.name] = max(0, min(1, v)) }
        }

        setupMenuBar()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(systemWillSleep),
            name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(systemDidWake),
            name: NSWorkspace.screensDidWakeNotification, object: nil)

        for screen in NSScreen.screens {
            let name = screen.localizedName
            if let path = lastSources[name],
               FileManager.default.fileExists(atPath: path) {
                show(on: screen, path: path)
            }
        }

        // macOS may reset desktop images briefly after launch.
        for delay in [1.0, 3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.enforceBlackOnActiveScreens()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        flushPendingPersist()
        for player in players.values { player.pause() }
        // NSWorkspace observers live on a separate notification center.
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        restoreSystemWallpaper()
        cleanupBackup()
    }

    private func enforceBlackOnActiveScreens() {
        for screen in NSScreen.screens where activeSources[screen.localizedName] != nil {
            try? NSWorkspace.shared.setDesktopImageURL(blackImageURL, for: screen, options: [:])
        }
    }

    // MARK: menubar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button { button.title = "▶" }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let screens = NSScreen.screens

        for (idx, screen) in screens.enumerated() {
            appendScreenBlock(to: menu, screenIndex: idx, screen: screen)
            if idx < screens.count - 1 { menu.addItem(.separator()) }
        }

        menu.addItem(.separator())

        let langItem = NSMenuItem(title: L.language, action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        let zh = NSMenuItem(title: L.langZh, action: #selector(setLangZh), keyEquivalent: "")
        let en = NSMenuItem(title: L.langEn, action: #selector(setLangEn), keyEquivalent: "")
        zh.target = self; en.target = self
        zh.state = (L.lang == .zh) ? .on : .off
        en.state = (L.lang == .en) ? .on : .off
        langMenu.addItem(zh); langMenu.addItem(en)
        langItem.submenu = langMenu
        menu.addItem(langItem)

        let quitItem = NSMenuItem(title: L.quit, action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // header / Select Wallpaper… / Volume / [Pause|Resume] / [Stop|Restore]
    private func appendScreenBlock(to menu: NSMenu, screenIndex: Int, screen: NSScreen) {
        let name = screen.localizedName

        let headerTitle = "— \(name) (\(screenIndex + 1)) —"
        let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let headerWidth = (headerTitle as NSString)
            .size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width

        let select = NSMenuItem(title: L.selectWallpaper,
                                action: #selector(selectForScreen(_:)),
                                keyEquivalent: "")
        select.target = self
        select.tag = screenIndex
        menu.addItem(select)

        let isActive = activeSources[name] != nil

        if isActive {
            menu.addItem(makeVolumeItem(screenName: name, headerWidth: headerWidth))
        }

        if isActive {
            let paused = pausedScreens.contains(name)
            let item = NSMenuItem(title: paused ? L.resume : L.pause,
                                  action: #selector(togglePauseScreen(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = screenIndex
            menu.addItem(item)
        }

        if isActive {
            let item = NSMenuItem(title: L.stop,
                                  action: #selector(stopScreen(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = screenIndex
            menu.addItem(item)
        } else if lastSources[name] != nil {
            let item = NSMenuItem(title: L.restore,
                                  action: #selector(restoreScreen(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = screenIndex
            menu.addItem(item)
        }
    }

    // Volume container width = headerWidth so it doesn't enlarge the menu.
    private func makeVolumeItem(screenName: String, headerWidth: CGFloat) -> NSMenuItem {
        let vol = volumeByScreen[screenName] ?? defaultVolume
        let step = Int((vol * Float(volumeSteps)).rounded())
        let pct = step * (100 / volumeSteps)

        let labelX: CGFloat = 14
        let labelW: CGFloat = 95
        let sliderX = labelX + labelW + 1
        let containerW = max(60, ceil(headerWidth))
        let sliderW = max(20, containerW - sliderX)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: containerW, height: 22))

        let label = NSTextField(labelWithString: "\(L.volume) \(pct)%")
        label.frame = NSRect(x: labelX, y: 2, width: labelW, height: 18)
        label.font = NSFont.menuFont(ofSize: 0)
        label.textColor = .labelColor
        container.addSubview(label)

        let slider = NSSlider(
            value: Double(step), minValue: 0, maxValue: Double(volumeSteps),
            target: self, action: #selector(volumeChanged(_:)))
        slider.frame = NSRect(x: sliderX, y: 2, width: sliderW, height: 18)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.numberOfTickMarks = volumeSteps + 1
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below
        // NSSlider.tag is Int; we need a String screen name → associated object.
        objc_setAssociatedObject(slider, &screenNameKey, screenName,
                                  .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(slider, &volumeLabelKey, label,
                                  .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        container.addSubview(slider)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusItem.menu { rebuildMenu() }
    }

    // MARK: menu actions

    // Validate sender.tag against current screens (hotplug between menu rebuild and click).
    private func screenForTag(_ sender: NSMenuItem) -> NSScreen? {
        let screens = NSScreen.screens
        guard sender.tag >= 0, sender.tag < screens.count else { return nil }
        return screens[sender.tag]
    }

    @objc private func selectForScreen(_ sender: NSMenuItem) {
        guard let screen = screenForTag(sender) else { return }
        let name = screen.localizedName

        let panel = NSOpenPanel()
        panel.title = L.openPanelTitle
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if let cur = activeSources[name] ?? lastSources[name] {
            panel.directoryURL = URL(fileURLWithPath: cur).deletingLastPathComponent()
        } else {
            panel.directoryURL = FileManager.default.urls(
                for: .moviesDirectory, in: .userDomainMask).first
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let ext = url.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext) else {
            let alert = NSAlert()
            alert.messageText = L.unsupportedFile
            alert.runModal()
            return
        }

        show(on: screen, path: url.path)
        schedulePersist()
    }

    @objc private func togglePauseScreen(_ sender: NSMenuItem) {
        guard let screen = screenForTag(sender) else { return }
        let name = screen.localizedName
        guard let player = players[name] else { return }
        if pausedScreens.contains(name) {
            pausedScreens.remove(name)
            player.play()
        } else {
            pausedScreens.insert(name)
            player.pause()
        }
        rebuildMenu()
    }

    @objc private func stopScreen(_ sender: NSMenuItem) {
        guard let screen = screenForTag(sender) else { return }
        stop(screen: screen)
        schedulePersist()
        rebuildMenu()
    }

    @objc private func restoreScreen(_ sender: NSMenuItem) {
        guard let screen = screenForTag(sender) else { return }
        let name = screen.localizedName
        guard let path = lastSources[name] else { return }
        if !FileManager.default.fileExists(atPath: path) {
            lastSources.removeValue(forKey: name)
            schedulePersist()
            let alert = NSAlert()
            alert.messageText = L.unsupportedFile
            alert.informativeText = L.fileMissing
            alert.runModal()
            rebuildMenu()
            return
        }
        show(on: screen, path: path)
        schedulePersist()
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        guard let name = objc_getAssociatedObject(sender, &screenNameKey) as? String
        else { return }
        let step = Int(sender.doubleValue.rounded())
        let v = max(0, min(1, Float(step) / Float(volumeSteps)))
        volumeByScreen[name] = v
        players[name]?.volume = v
        if let label = objc_getAssociatedObject(sender, &volumeLabelKey) as? NSTextField {
            let pct = step * (100 / volumeSteps)
            label.stringValue = "\(L.volume) \(pct)%"
        }
        schedulePersist()
    }

    @objc private func setLangZh() { L.lang = .zh; schedulePersist(); rebuildMenu() }
    @objc private func setLangEn() { L.lang = .en; schedulePersist(); rebuildMenu() }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    // MARK: screen topology + sleep/wake

    @objc private func screensDidChange() {
        let live = Set(NSScreen.screens.map { $0.localizedName })

        for name in Set(activeSources.keys).subtracting(live) {
            teardown(name: name)
            activeSources.removeValue(forKey: name)
            pausedScreens.remove(name)
            volumeByScreen.removeValue(forKey: name)
        }
        for screen in NSScreen.screens {
            let name = screen.localizedName
            if activeSources[name] == nil,
               let path = lastSources[name],
               FileManager.default.fileExists(atPath: path) {
                show(on: screen, path: path)
            }
        }
        schedulePersist()
        rebuildMenu()
    }

    @objc private func systemWillSleep() {
        // Guard against overwrite when multiple sleep notifications arrive.
        if preSystemPauseSnapshot == nil {
            preSystemPauseSnapshot = pausedScreens
        }
        for name in activeSources.keys where !pausedScreens.contains(name) {
            players[name]?.pause()
            pausedScreens.insert(name)
        }
    }

    @objc private func systemDidWake() {
        // Re-enforce black: wake races against WallpaperAgent re-rendering.
        enforceBlackOnActiveScreens()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.enforceBlackOnActiveScreens()
        }

        guard let snapshot = preSystemPauseSnapshot else { return }
        preSystemPauseSnapshot = nil
        for name in activeSources.keys where !snapshot.contains(name) {
            pausedScreens.remove(name)
            players[name]?.play()
        }
        rebuildMenu()
    }

    // MARK: show / stop / teardown

    // Fail loud if the file disappeared between selection and show (would
    // otherwise just show a black wallpaper with no diagnostic).
    private func show(on screen: NSScreen, path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            FileHandle.standardError.write(Data("vidpaper: show: file missing: \(path)\n".utf8))
            return
        }
        let name = screen.localizedName
        teardown(name: name)

        let vol = volumeByScreen[name] ?? defaultVolume
        let window = createWallpaperWindow(screen: screen)
        let player = setupVideoContent(window: window, screen: screen, path: path, volume: vol)
        window.orderFront(nil)

        windows[name] = window
        players[name] = player
        activeSources[name] = path
        lastSources[name] = path
        pausedScreens.remove(name)

        try? NSWorkspace.shared.setDesktopImageURL(blackImageURL, for: screen, options: [:])
        rebuildMenu()
    }

    // lastSources kept so the user can Restore later. ~1-3s gap while the
    // WallpaperAgent restarts.
    private func stop(screen: NSScreen) {
        let name = screen.localizedName
        teardown(name: name)
        activeSources.removeValue(forKey: name)
        pausedScreens.remove(name)
        restoreSystemWallpaper()
        // Other screens still active — agent respawn cleared their black, push it back.
        if !activeSources.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.enforceBlackOnActiveScreens()
            }
        }
    }

    private func teardown(name: String) {
        players[name]?.pause()
        windows[name]?.orderOut(nil)
        windows.removeValue(forKey: name)
        players.removeValue(forKey: name)
    }

    // MARK: persistence

    private func schedulePersist() {
        persistTimer?.invalidate()
        persistTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistNow() }
        }
    }

    private func flushPendingPersist() {
        persistTimer?.invalidate()
        persistTimer = nil
        persistNow()
    }

    private func persistNow() {
        let allNames = Set(activeSources.keys)
            .union(lastSources.keys)
            .union(volumeByScreen.keys)
        var screens: [ScreenState] = []
        for name in allNames.sorted() {
            screens.append(ScreenState(
                name: name,
                lastPath: lastSources[name],
                volume: volumeByScreen[name]))
        }
        let state = PersistedState(lang: L.lang.rawValue, screens: screens)
        saveState(state)
    }
}

private var screenNameKey: UInt8 = 0
private var volumeLabelKey: UInt8 = 0

// MARK: - main

// Held for the process lifetime so the signal sources are not deallocated.
private var signalSources: [DispatchSourceSignal] = []

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate

    // Route SIGTERM/SIGINT (e.g. from `vidpaper-stop`) through AppKit's normal
    // termination so applicationWillTerminate runs and restores the wallpaper.
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { NSApplication.shared.terminate(nil) }
        source.resume()
        signalSources.append(source)
    }

    app.run()
}
