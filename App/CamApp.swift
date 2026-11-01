import SwiftUI
import AVFoundation

@main
struct USBCamApp: App {
    var body: some Scene {
        WindowGroup { ContentView().preferredColorScheme(.dark) }
    }
}

struct ContentView: View {
    @StateObject private var s = Streamer()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PreviewView(session: s.session).ignoresSafeArea()
            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle().fill(s.connected ? Color.green : Color.orange)
                                .frame(width: 10, height: 10)
                            Text(s.connected ? "Streaming to PC" : "Waiting for PC")
                                .font(.footnote.bold())
                        }
                        Text(s.activeInfo).font(.caption2)
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(10)
                    Spacer()
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title2)
                            .padding(10)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                }
                Spacer()
            }
            .padding()
        }
        .foregroundColor(.white)
        .sheet(isPresented: $showSettings) { SettingsView(s: s) }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            s.start()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var s: Streamer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Resolution")) {
                    Picker("Resolution", selection: $s.resolution) {
                        ForEach(Res.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented)
                }
                Section(header: Text("Frame rate")) {
                    Picker("FPS", selection: $s.fps) {
                        ForEach([15, 24, 30, 60], id: \.self) { Text("\($0)").tag($0) }
                    }.pickerStyle(.segmented)
                }
                Section(header: Text("Camera")) {
                    Picker("Camera", selection: $s.front) {
                        Text("Back").tag(false)
                        Text("Front").tag(true)
                    }.pickerStyle(.segmented)
                }
                Section(header: Text("Active")) {
                    Text(s.activeInfo)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct PreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        return v
    }
    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let c = previewLayer.connection, c.isVideoOrientationSupported {
            let o = window?.windowScene?.interfaceOrientation
            c.videoOrientation = (o == .landscapeLeft) ? .landscapeLeft : .landscapeRight
        }
    }
}
