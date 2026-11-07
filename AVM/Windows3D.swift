// Windows3D.swift
// AVM — Accessible Virtual Machine
//
// DirectX for Windows machines (2026-11-01, experimental, off unless chosen):
// Settings, Display and Sound, 3D Graphics. It's UTM's stack: Windows' DirectX
// goes through osy's driver (viogpu3d, Microsoft-signed, so it loads with
// Secure Boot on) over virtio-gpu to virglrenderer's Neptune, and DXMT draws
// it with Metal. D3DMetal, which adds Direct3D 12, is left out: Apple's terms
// don't let AVM ship it.
//
// MEASURED 2026-11-01 on Windows 11 26100.4349 with driver v0.5: pnputil
// installs it with no prompt and the device starts at once; the first restart
// after that takes several minutes, with the disk busy; NVDA runs alongside
// it. The driver's author says it's still unstable, so Settings takes a
// restore point before turning it on (SettingsView).
//
// QEMU's screendump is black once the driver draws, as the picture is on the
// GPU; screenPicture (VMManager) reads it from CocoaSpice instead.

import Foundation

extension VMManager {

    /// virglrenderer built with Neptune, its render server and DXMT
    /// (Tools/build-sysroot.sh --windows-3d), and the Windows driver.
    static let supportsWindows3D: Bool = {
        guard let resources = Bundle.main.resourceURL else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: resources.appendingPathComponent("libdxmt-native.dylib").path)
            && fm.isExecutableFile(atPath: resources.appendingPathComponent("virgl_render_server").path)
            && fm.fileExists(atPath: resources.appendingPathComponent("viogpu3d/viogpu3d.inf").path)
    }()

    /// What virglrenderer reads to find its render server and DXMT.
    nonisolated static func windows3DEnvironment(resources: String) -> [String: String] {
        let dxmt = "\(resources)/libdxmt-native.dylib"
        return ["RENDER_SERVER_EXEC_PATH": "\(resources)/virgl_render_server",
                "NPT_BACKEND": "dxmt",
                "NPT_D3D11_LIBRARY_PATH": dxmt,
                "NPT_D3D12_LIBRARY_PATH": dxmt,
                "NPT_DXGI_LIBRARY_PATH": dxmt]
    }

    /// The driver, put into a running Windows machine the first time it runs
    /// with 3D on. Its files are staged under C:\Windows\Temp, in a folder
    /// only SYSTEM makes (2026-11-05, second audit: in ProgramData a standard
    /// user could own the folder first and swap the driver).
    func installWindows3DDriverIfNeeded(machine: String) async {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("viogpu3d"),
              let files = try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return }
        // Its agent, up to five minutes after the start.
        var answered = false
        for _ in 0..<60 {
            if Task.isCancelled { return }
            if (try? await agentRun("cmd.exe", ["/c", "ver"], limit: .seconds(20))) != nil { answered = true; break }
            try? await Task.sleep(for: .seconds(5))
        }
        guard answered else {
            Announcer.shared.announce("\(machine)'s 3D graphics driver couldn't be installed: its guest agent isn't answering. Next: restart \(machine) to try again.", tone: .failure)
            return
        }
        let devices = (try? await agentRun("pnputil.exe", ["/enum-devices", "/class", "Display"], limit: .seconds(60))) ?? ""
        if devices.contains("VirtIO GPU 3D") { return }
        Announcer.shared.announce("Installing the 3D graphics driver in \(machine).", tone: .info)
        let folder = #"C:\Windows\Temp\AVM-viogpu3d-"# + String(UUID().uuidString.prefix(8))
        // Three tries (2026-11-01, the test job): just after Windows starts
        // its agent can miss an answer, and one miss said to turn 3D off.
        var lastError: Error?
        for attempt in 1...3 {
            if Task.isCancelled { return }
            do {
                _ = try await agentRun("cmd.exe", ["/c", "if not exist \(folder) mkdir \(folder)"], limit: .seconds(30))
                for file in files {
                    try await copyToGuest(file, to: folder + "\\" + file.lastPathComponent)
                }
                let out = try await agentRun("pnputil.exe", ["/add-driver", folder + #"\viogpu3d.inf"#, "/install"], limit: .seconds(180))
                guard out.contains("Driver package installed on device") || out.contains("Added driver packages:  1") else {
                    throw AVMError.qmpCommandFailed(out.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                AVMLog.write("AVM: Windows 3D — driver installed in \(machine)")
                Announcer.shared.announce("\(machine)'s 3D graphics driver is installed. Next: restart \(machine) to use it. The first restart can take several minutes.", tone: .success)
                return
            } catch {
                lastError = error
                AVMLog.write("AVM: Windows 3D — try \(attempt) didn't finish: \(error.localizedDescription)")
                try? await Task.sleep(for: .seconds(30))
            }
        }
        Announcer.shared.announce("\(machine)'s 3D graphics driver couldn't be installed. Reason: \(lastError?.localizedDescription ?? "unknown") Next: turn 3D Graphics off in its Settings, or try starting it again.", tone: .failure)
    }
}
