import SwiftUI
import Core
import AVFoundation

@main
struct NoNoiseMacApp: App {
    // We bind the AppDelegate to handle application lifecycle events if needed
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    // The Core Logic
    @StateObject var audioModel = AudioModel()
    
    var body: some Scene {
        MenuBarExtra {
            ContentView(audioModel: audioModel)
        } label: {
            Image(nsImage: NoNoiseLogoImage.menuBar(isActive: audioModel.isAIEnabled))
        }
        .menuBarExtraStyle(.window) // Allows complex SwiftUI view in menu
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon explicitly just in case Info.plist didn't catch it quickly (redundant but safe)
        NSApp.setActivationPolicy(.accessory)
    }
}
