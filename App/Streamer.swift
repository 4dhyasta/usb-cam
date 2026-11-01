import AVFoundation
import VideoToolbox
import Network
import UIKit

enum Res: Int, CaseIterable {
    case p540 = 540, p720 = 720, p1080 = 1080
    var size: (Int, Int) {
        switch self {
        case .p540: return (960, 540)
        case .p720: return (1280, 720)
        case .p1080: return (1920, 1080)
        }
    }
    var label: String { "\(rawValue)p" }
}

final class Streamer: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let port: NWEndpoint.Port = 5005

    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "cam.main", qos: .userInteractive)
    private let sessionQueue = DispatchQueue(label: "cam.session")
    private var input: AVCaptureDeviceInput?
    private var started = false

    @Published var connected = false
    @Published var activeInfo = ""
    @Published var resolution: Res {
        didSet { UserDefaults.standard.set(resolution.rawValue, forKey: "res"); configure() }
    }
    @Published var fps: Int {
        didSet { UserDefaults.standard.set(fps, forKey: "fps"); configure() }
    }
    @Published var front: Bool {
        didSet { UserDefaults.standard.set(front, forKey: "front"); configure() }
    }

    // everything below is only touched on `queue`
    private var listener: NWListener?
    private var conn: NWConnection?
    private var hasClient = false
    private var needKey = false
    private var waitKey = false
    private var pending = 0
    private var enc: VTCompressionSession?
    private var encW: Int32 = 0
    private var encH: Int32 = 0
    private var activeFps = 30
    private var orientation: AVCaptureVideoOrientation = .landscapeRight

    override init() {
        let ud = UserDefaults.standard
        resolution = Res(rawValue: ud.integer(forKey: "res")) ?? .p1080
        let f = ud.integer(forKey: "fps")
        fps = f == 0 ? 30 : f
        front = ud.bool(forKey: "front")
        super.init()
    }

    // MARK: start / configure

    func start() {
        guard !started else { return }
        started = true
        queue.async { self.startListener() }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.updateOrientation()
        }
        AVCaptureDevice.requestAccess(for: .video) { ok in
            if ok { self.configure() }
            else { DispatchQueue.main.async { self.activeInfo = "Camera permission denied" } }
        }
    }

    private func updateOrientation() {
        var v: AVCaptureVideoOrientation
        switch UIDevice.current.orientation {
        case .landscapeLeft: v = .landscapeRight
        case .landscapeRight: v = .landscapeLeft
        default: return
        }
        queue.async {
            self.orientation = v
            self.applyOrientation()
        }
    }

    private func applyOrientation() {
        if let c = output.connection(with: .video), c.isVideoOrientationSupported {
            c.videoOrientation = orientation
        }
    }

    func configure() {
        guard started else { return }
        let res = resolution, want = fps, useFront = front
        sessionQueue.async { self.configureSession(res, want, useFront) }
    }

    private func configureSession(_ res: Res, _ want: Int, _ useFront: Bool) {
        session.beginConfiguration()
        if let old = input { session.removeInput(old); input = nil }
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                position: useFront ? .front : .back),
              let inp = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(inp) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.activeInfo = "Camera not available" }
            return
        }
        session.addInput(inp)
        input = inp

        if !session.outputs.contains(output) {
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                        kCVPixelFormatType_420YpCbCrBiPlanarVideoRange]
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }

        let (w, h) = res.size
        var best: AVCaptureDevice.Format?
        var bestMax = 0.0
        for f in dev.formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard Int(d.width) == w, Int(d.height) == h else { continue }
            let m = f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            if m > bestMax { bestMax = m; best = f }
        }
        var actual = want
        if let fmt = best {
            actual = min(want, Int(bestMax.rounded()))
            do {
                try dev.lockForConfiguration()
                dev.activeFormat = fmt
                let dur = CMTime(value: 1, timescale: CMTimeScale(actual))
                dev.activeVideoMinFrameDuration = dur
                dev.activeVideoMaxFrameDuration = dur
                dev.unlockForConfiguration()
            } catch {}
        }
        session.commitConfiguration()

        queue.async {
            self.activeFps = actual
            self.applyOrientation()
            self.teardownEncoder()
        }
        if !session.isRunning { session.startRunning() }

        let note = actual < want ? " (max for this mode)" : ""
        DispatchQueue.main.async { self.activeInfo = "\(w)x\(h) @ \(actual) fps\(note)" }
    }

    // MARK: network (listens on the phone; the PC connects through the USB cable)

    private func startListener() {
        do {
            let p = NWParameters.tcp
            p.allowLocalEndpointReuse = true
            if let tcp = p.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcp.noDelay = true
            }
            let l = try NWListener(using: p, on: Streamer.port)
            l.newConnectionHandler = { [weak self] c in
                self?.queue.async { self?.accept(c) }
            }
            l.stateUpdateHandler = { [weak self] st in
                if case .failed = st {
                    self?.queue.asyncAfter(deadline: .now() + 1) { self?.startListener() }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startListener() }
        }
    }

    private func accept(_ c: NWConnection) {
        conn?.cancel()
        conn = c
        pending = 0
        c.stateUpdateHandler = { [weak self] st in
            guard let self = self else { return }
            switch st {
            case .ready:
                self.queue.async { if self.conn === c { self.setClient(true) } }
            case .failed, .cancelled:
                self.queue.async { if self.conn === c { self.conn = nil; self.setClient(false) } }
            default: break
            }
        }
        c.start(queue: queue)
        receive(c)
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] _, _, done, err in
            if done || err != nil { c.cancel(); return }
            self?.receive(c)
        }
    }

    private func setClient(_ on: Bool) {
        hasClient = on
        if on { needKey = true; waitKey = true } else { teardownEncoder() }
        DispatchQueue.main.async { self.connected = on }
    }

    private func send(_ pkt: Data, isKey: Bool) {
        guard hasClient, let c = conn else { return }
        if waitKey {
            if !isKey { return }
            waitKey = false
        }
        if pending > 4 && !isKey {          // link is backed up: drop and resync on next keyframe
            waitKey = true; needKey = true
            return
        }
        pending += 1
        c.send(content: pkt, completion: .contentProcessed { [weak self] _ in
            self?.queue.async { self?.pending -= 1 }
        })
    }

    // MARK: capture -> H.264

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard hasClient, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let w = Int32(CVPixelBufferGetWidth(pb)), h = Int32(CVPixelBufferGetHeight(pb))
        if enc == nil || w != encW || h != encH { makeEncoder(w, h) }
        guard let e = enc else { return }
        var props: CFDictionary?
        if needKey {
            needKey = false
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(e, imageBuffer: pb,
                                        presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                                        duration: .invalid, frameProperties: props,
                                        sourceFrameRefcon: nil, infoFlagsOut: nil)
    }

    private func makeEncoder(_ w: Int32, _ h: Int32) {
        teardownEncoder()
        let cb: VTCompressionOutputCallback = { refcon, _, status, _, sb in
            guard status == noErr, let sb = sb, let refcon = refcon else { return }
            Unmanaged<Streamer>.fromOpaque(refcon).takeUnretainedValue().handleEncoded(sb)
        }
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: w, height: h,
                                            codecType: kCMVideoCodecType_H264,
                                            encoderSpecification: nil, imageBufferAttributes: nil,
                                            compressedDataAllocator: nil, outputCallback: cb,
                                            refcon: Unmanaged.passUnretained(self).toOpaque(),
                                            compressionSessionOut: &s)
        guard st == noErr, let sess = s else { return }
        let bitrate = min(max(Int(Double(w) * Double(h) * Double(activeFps) * 0.15), 2_000_000), 40_000_000)
        func set(_ k: CFString, _ v: CFTypeRef) { VTSessionSetProperty(sess, key: k, value: v) }
        set(kVTCompressionPropertyKey_RealTime, NSNumber(value: true))
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, NSNumber(value: false))
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: activeFps))
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: activeFps))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 1))
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        VTCompressionSessionPrepareToEncodeFrames(sess)
        enc = sess; encW = w; encH = h
        needKey = true
    }

    private func teardownEncoder() {
        if let e = enc {
            VTCompressionSessionCompleteFrames(e, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(e)
        }
        enc = nil; encW = 0; encH = 0
    }

    // Called on a VideoToolbox thread. Converts AVCC -> Annex B and frames it:
    // [1 byte keyframe flag][4 bytes big-endian length][annex-b access unit]
    fileprivate func handleEncoded(_ sb: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sb) else { return }
        var isKey = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let a = arr.first {
            isKey = !((a[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        }
        let start: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        if isKey, let fd = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var p: UnsafePointer<UInt8>?
                var sz = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i,
                    parameterSetPointerOut: &p, parameterSetSizeOut: &sz,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let p = p { out.append(contentsOf: start); out.append(p, count: sz) }
            }
        }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        var len = 0
        var ptr: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &len, dataPointerOut: &ptr)
        guard let base = ptr else { return }
        base.withMemoryRebound(to: UInt8.self, capacity: len) { p in
            var off = 0
            while off + 4 <= len {
                let n = Int(p[off]) << 24 | Int(p[off + 1]) << 16 | Int(p[off + 2]) << 8 | Int(p[off + 3])
                off += 4
                if n <= 0 || off + n > len { break }
                out.append(contentsOf: start)
                out.append(p + off, count: n)
                off += n
            }
        }
        var pkt = Data([isKey ? 1 : 0])
        var be = UInt32(out.count).bigEndian
        pkt.append(Data(bytes: &be, count: 4))
        pkt.append(out)
        queue.async { self.send(pkt, isKey: isKey) }
    }
}
