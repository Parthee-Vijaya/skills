import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.Key.outputLocation) private var outputLocation = OutputLocation.besideOriginal.rawValue
    @AppStorage(Prefs.Key.customOutputPath) private var customOutputPath = ""
    @AppStorage(Prefs.Key.revealInFinder) private var revealInFinder = true
    @AppStorage(Prefs.Key.playSound) private var playSound = true
    @AppStorage(Prefs.Key.imageQuality) private var imageQuality = 0.85
    @AppStorage(Prefs.Key.isPaused) private var isPaused = false
    @AppStorage(Prefs.Key.ffmpegPath) private var ffmpegPath = ""
    @AppStorage(Prefs.Key.filesProcessed) private var filesProcessed = 0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var detectedFFmpeg = FFmpeg.path

    var body: some View {
        Form {
            Section("Genveje") {
                LabeledContent("Konvertér") { Text("Hold ⇧ mens du trækker en fil").foregroundStyle(.secondary) }
                LabeledContent("Værktøjer") { Text("Hold ⌥⇧ mens du trækker en fil").foregroundStyle(.secondary) }
                Toggle("Sæt Bumlebee på pause", isOn: $isPaused)
            }

            Section("Resultater") {
                Picker("Gem nye filer", selection: $outputLocation) {
                    ForEach(OutputLocation.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if outputLocation == OutputLocation.custom.rawValue {
                    HStack {
                        Text(customOutputPath.isEmpty ? "Ingen mappe valgt" : customOutputPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Vælg …") { chooseFolder() }
                    }
                }
                Toggle("Vis resultatet i Finder", isOn: $revealInFinder)
                Toggle("Afspil lyd, når et job er færdigt", isOn: $playSound)
                VStack(alignment: .leading) {
                    Text("Billedkvalitet (JPEG, HEIC, WebP): \(Int(imageQuality * 100)) %")
                    Slider(value: $imageQuality, in: 0.4...1, step: 0.05)
                        .tint(Theme.honeyDeep)
                }
            }

            Section("ffmpeg (valgfrit)") {
                Text("macOS kan selv klare de fleste formater. MP3, OGG, Opus, MKV, WebM, AVI og WMV kræver ffmpeg. WebP og AVIF laves med ffmpeg eller med cwebp/avifenc.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("Status") {
                    if let detectedFFmpeg {
                        Label(detectedFFmpeg, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Ikke fundet", systemImage: "xmark.circle").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Kopiér installationskommando") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install ffmpeg webp libavif", forType: .string)
                    }
                    Button("Vælg ffmpeg …") { chooseFFmpeg() }
                    Button("Søg igen") { detectedFFmpeg = FFmpeg.path }
                }
            }

            Section("Generelt") {
                Toggle("Start Bumlebee ved login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                LabeledContent("Filer behandlet") { Text("\(filesProcessed)") }
                LabeledContent("Privatliv") { Text("Alt sker lokalt på din Mac").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Vælg"
        if panel.runModal() == .OK, let url = panel.url { customOutputPath = url.path }
    }

    private func chooseFFmpeg() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        panel.prompt = "Brug"
        if panel.runModal() == .OK, let url = panel.url {
            ffmpegPath = url.path
            detectedFFmpeg = FFmpeg.path
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            Alerts.error(title: "Kunne ikke ændre login-indstillingen", message: error.localizedDescription)
        }
    }
}

struct WelcomeView: View {
    let onDone: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 22) {
            BeeMark(size: 96)
                .padding(.top, 28)
            VStack(spacing: 6) {
                Text("Bumlebee")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                Text("Konvertér filer dér, hvor du allerede er.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                step("hand.draw", "Træk en fil i Finder", "Et billede, en video, en lydfil, en PDF eller et dokument.")
                step("shift", "Hold ⇧ Shift undervejs", "Et hjul af honningceller med formater dukker op om markøren.")
                step("hexagon", "Slip filen på et format", "Den konverterede kopi lægges ved siden af originalen.")
                step("option", "Hold ⌥ Option + ⇧ Shift for værktøjer", "Komprimér, beskær, klip, fjern metadata, læs QR-koder og meget mere.")
            }
            .padding(.horizontal, 36)
            Text("Alt sker på din Mac. Intet bliver sendt nogen steder hen.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Kom i gang") {
                Prefs.hasSeenOnboarding = true
                onDone()
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.honeyDeep)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.bottom, 24)
        }
        .frame(width: 560, height: 600)
        .background(
            LinearGradient(colors: [Theme.honey.opacity(0.22), Color(nsColor: .windowBackgroundColor)], startPoint: .top, endPoint: .center)
        )
    }

    private func step(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 36, height: 36)
                .background(Hexagon(cornerRadius: 5).fill(Theme.honey))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
