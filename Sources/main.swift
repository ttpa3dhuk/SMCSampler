// SMC Sampler: eight independent audio slots with CoreMIDI feedback.
// Build with ./build.sh. Playback is locked on every launch.
import Cocoa
import AVFoundation
import AudioToolbox
import CoreMIDI
import UniformTypeIdentifiers

func endpointName(_ endpoint: MIDIEndpointRef) -> String {
    var name: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
    return name?.takeRetainedValue() as String? ?? "Unknown"
}

final class MIDI {
    var client = MIDIClientRef(), input = MIDIPortRef(), output = MIDIPortRef()
    var source = MIDIEndpointRef(), destination = MIDIEndpointRef()
    var receive: (([UInt8]) -> Void)?
    var connection: ((String) -> Void)?
    var pending: [UInt8] = []
    var running: UInt8 = 0
    init() {
        MIDIClientCreateWithBlock("SMC Sampler" as CFString, &client) { [weak self] _ in
            DispatchQueue.main.async { self?.connect() }
        }
        MIDIInputPortCreateWithBlock(client, "Input" as CFString, &input) { [weak self] list, _ in
            var pointer = UnsafeRawPointer(list).advanced(by: MemoryLayout<MIDIPacketList>.offset(of: \.packet)!).assumingMemoryBound(to: MIDIPacket.self)
            for _ in 0..<list.pointee.numPackets {
                let packet = pointer.pointee
                let bytes = withUnsafeBytes(of: packet.data) { Array($0.prefix(Int(packet.length))) }
                DispatchQueue.main.async { self?.parse(bytes) }
                pointer = UnsafePointer(MIDIPacketNext(pointer))
            }
        }
        MIDIOutputPortCreate(client, "Lights" as CFString, &output)
    }
    func parse(_ bytes: [UInt8]) {
        for byte in bytes {
            if byte >= 0xF8 { continue }
            if byte & 0x80 != 0 {
                pending = []
                running = byte < 0xF0 ? byte : 0
                continue
            }
            guard running != 0 else { continue }
            pending.append(byte)
            let required = (running & 0xF0 == 0xC0 || running & 0xF0 == 0xD0) ? 1 : 2
            if pending.count == required { receive?([running] + pending); pending = [] }
        }
    }
    func connect() {
        func choose(_ endpoints: [MIDIEndpointRef]) -> MIDIEndpointRef {
            let matches = endpoints.filter { endpointName($0).localizedCaseInsensitiveContains("SMC") }
            return matches.first(where: { endpointName($0).localizedCaseInsensitiveContains("Bluetooth") }) ?? matches.first ?? 0
        }
        let next = choose((0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) })
        let nextDestination = choose((0..<MIDIGetNumberOfDestinations()).map { MIDIGetDestination($0) })
        guard next != source || nextDestination != destination else { return }
        if source != 0 { MIDIPortDisconnectSource(input, source) }
        source = next; destination = nextDestination; pending = []; running = 0
        if source != 0 { MIDIPortConnectSource(input, source, nil) }
        connection?(source == 0 ? "SMC не подключён" : endpointName(source) + (destination == 0 ? " · нет выхода ламп" : " · подключён"))
    }
    func lamp(_ index: Int, _ on: Bool, loaded: Bool = false) {
        guard destination != 0 else { return }
        var list = MIDIPacketList()
        let bytes: [UInt8] = [0x90, UInt8((loaded ? 8 : 24) + index), on ? 127 : 0]
        withUnsafeMutablePointer(to: &list) { ptr in
            let packet = MIDIPacketListInit(ptr)
            bytes.withUnsafeBufferPointer { buffer in
                _ = MIDIPacketListAdd(ptr, MemoryLayout<MIDIPacketList>.size, packet, 0, 3, buffer.baseAddress!)
            }
            MIDISend(output, destination, ptr)
        }
    }
}

func timeRemaining(_ duration: TimeInterval, _ position: TimeInterval) -> String {
    let seconds = Int(ceil(max(0, duration - position)))
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}

func samplerError(_ text: String) -> NSError {
    NSError(domain: "SMC Sampler", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
}

struct AudioDevice {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

func audioPropertyString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let string = value?.takeRetainedValue() else { return nil }
    return string as String
}

func outputDeviceChannels(_ id: AudioDeviceID) -> Int {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { storage.deallocate() }
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func outputDevices() -> [AudioDevice] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        guard outputDeviceChannels(id) > 0,
              let name = audioPropertyString(id, kAudioObjectPropertyName),
              let uid = audioPropertyString(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioDevice(id: id, name: name, uid: uid)
    }
}

func defaultOutputDevice() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
    return id
}

// Playback owns the audio engine, the eight slots and the output device.
// AVAudioPlayer cannot target a specific device, so slots are player nodes.
final class Playback {
    static let canonical = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    let engine = AVAudioEngine()
    let nodes: [AVAudioPlayerNode] = (0..<8).map { _ in AVAudioPlayerNode() }
    var buffers: [AVAudioPCMBuffer?] = Array(repeating: nil, count: 8)
    var levels = [Float](repeating: 0, count: 8)
    var trims = [Float](repeating: 0, count: 8)
    var master: Float = 1
    var startedAt: [Date?] = Array(repeating: nil, count: 8)
    var generation = [Int](repeating: 0, count: 8)
    var playing = [Bool](repeating: false, count: 8)
    var finished = Set<Int>()
    var onEnd: ((Int) -> Void)?
    var output: AudioDevice?
    let meterLock = NSLock()
    var powers = [Float](repeating: -160, count: 8)
    var peaks = [Float](repeating: -160, count: 8)
    var tapCount = 0
    var prepared = false

    func prepare() throws {
        guard !prepared else { return }
        for (index, node) in nodes.enumerated() {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: Playback.canonical)
            node.installTap(onBus: 0, bufferSize: 1024, format: Playback.canonical) { [weak self] buffer, _ in
                self?.measure(index, buffer)
            }
        }
        engine.prepare()
        prepared = true
    }

    func start() throws {
        try prepare()
        guard !engine.isRunning else { return }
        try engine.start()
    }

    func startIfNeeded() -> String? {
        if engine.isRunning { return nil }
        do { try start(); return nil } catch { return "аудио недоступно: \(error.localizedDescription)" }
    }

    func shutdown() {
        for i in 0..<8 { stop(i) }
        engine.stop()
    }

    // Creates the output device before the engine starts; restarting keeps it.
    func setOutput(_ device: AudioDevice?) throws {
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        try prepare()
        let target = device?.id ?? defaultOutputDevice()
        if let target, let unit = engine.outputNode.audioUnit {
            var id = target
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw samplerError("не удалось выбрать выход \(device?.name ?? "система") (\(status))") }
        }
        output = device
        engine.prepare()
        if wasRunning { try engine.start() }
    }

    static func canonicalize(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let format = input.format
        if format.sampleRate == canonical.sampleRate, format.channelCount == canonical.channelCount,
           format.commonFormat == .pcmFormatFloat32, !format.isInterleaved { return input }
        guard let converter = AVAudioConverter(from: format, to: canonical) else {
            throw samplerError("не удалось подготовить конвертер для \(format)")
        }
        let ratio = canonical.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 2048
        guard let output = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: capacity) else {
            throw samplerError("не хватило памяти на конвертацию")
        }
        var error: NSError?
        var supplied = false
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .endOfStream; return nil }
            supplied = true; outStatus.pointee = .haveData; return input
        }
        if status == .error { throw error ?? samplerError("ошибка конвертации файла") }
        guard output.frameLength > 0 else { throw samplerError("после конвертации не осталось звука") }
        return output
    }

    func load(_ url: URL, _ index: Int) throws {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { throw samplerError("файл пустой") }
        guard let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw samplerError("не хватило памяти на файл")
        }
        try file.read(into: raw)
        let buffer = try Playback.canonicalize(raw)
        stop(index)
        buffers[index] = buffer
    }

    func inject(_ index: Int, _ buffer: AVAudioPCMBuffer) {
        buffers[index] = buffer
    }

    func loaded(_ index: Int) -> Bool { buffers[index] != nil }
    func running(_ index: Int) -> Bool { playing[index] }
    func duration(_ index: Int) -> TimeInterval { Playback.seconds(buffers[index]) }

    static func seconds(_ buffer: AVAudioPCMBuffer?) -> TimeInterval {
        guard let buffer, buffer.format.sampleRate > 0 else { return 0 }
        return Double(buffer.frameLength) / buffer.format.sampleRate
    }

    func position(_ index: Int) -> TimeInterval {
        guard playing[index], let start = startedAt[index], let buffer = buffers[index] else { return 0 }
        return min(Playback.seconds(buffer), Date().timeIntervalSince(start))
    }

    func gain(_ index: Int) -> Float {
        levels[index] * master * pow(10, trims[index] / 20)
    }

    func meter(_ index: Int) -> (Float, Float) {
        meterLock.lock(); defer { meterLock.unlock() }
        return (powers[index], peaks[index])
    }

    func setLevel(_ index: Int, _ value: Float) {
        levels[index] = min(1, max(0, value))
        nodes[index].volume = gain(index)
    }

    func setTrim(_ index: Int, _ value: Float) {
        trims[index] = min(0, max(-60, value))
        nodes[index].volume = gain(index)
    }

    func setMaster(_ value: Float) {
        master = min(1, max(0, value))
        for i in 0..<8 { nodes[i].volume = gain(i) }
    }

    func trigger(_ index: Int) -> String? {
        if let problem = startIfNeeded() { return problem }
        guard let buffer = buffers[index] else { return "сначала добавь файл" }
        let node = nodes[index]
        generation[index] += 1
        let token = generation[index]
        node.stop()
        node.volume = gain(index)
        node.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            DispatchQueue.main.async { self?.ended(index, token) }
        }
        node.play()
        startedAt[index] = Date()
        playing[index] = true
        finished.remove(index)
        return nil
    }

    func stop(_ index: Int) {
        generation[index] += 1
        nodes[index].stop()
        playing[index] = false
        startedAt[index] = nil
        finished.remove(index)
        meterLock.lock(); powers[index] = -160; peaks[index] = -160; meterLock.unlock()
    }

    func ended(_ index: Int, _ token: Int) {
        guard generation[index] == token else { return }
        playing[index] = false
        startedAt[index] = nil
        finished.insert(index)
        meterLock.lock(); powers[index] = -160; peaks[index] = -160; meterLock.unlock()
        onEnd?(index)
    }

    func measure(_ index: Int, _ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return }
        var sum: Float = 0
        var maximum: Float = 0
        for channel in 0..<channels {
            let samples = data[channel]
            for frame in 0..<frames {
                let value = abs(samples[frame])
                sum += value * value
                maximum = max(maximum, value)
            }
        }
        let rms = sqrt(sum / Float(frames * channels))
        let powerDB = 20 * log10(max(rms, 1e-7))
        let peakDB = 20 * log10(max(maximum, 1e-7))
        meterLock.lock()
        tapCount += 1
        powers[index] = max(-60, min(0, powerDB))
        peaks[index] = max(-60, min(0, peakDB))
        meterLock.unlock()
    }
}

final class MeterSliderCell: NSSliderCell {
    var power: Float = -160
    var peak: Float = -160
    func update(power: Float, peak: Float) {
        self.power = power; self.peak = peak; controlView?.needsDisplay = true
    }
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.midX - 3, y: rect.minY, width: 6, height: rect.height)
        NSColor.darkGray.setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let fraction = CGFloat(min(1, max(0, (power + 60) / 60)))
        if fraction > 0 {
            let height = track.height * fraction
            let fill = NSRect(x: track.minX, y: flipped ? track.maxY - height : track.minY, width: track.width, height: height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).addClip()
            let gradient = NSGradient(colors: [.systemGreen, .systemYellow, .systemRed])!
            NSBezierPath(rect: fill).addClip()
            gradient.draw(in: track, angle: flipped ? -90 : 90)
            NSGraphicsContext.restoreGraphicsState()
        }
        let peakFraction = CGFloat(min(1, max(0, (peak + 60) / 60)))
        if peakFraction > 0, peak > power {
            let y = flipped ? track.maxY - track.height * peakFraction : track.minY + track.height * peakFraction
            NSColor.labelColor.setFill()
            NSRect(x: track.minX - 2, y: y - 1, width: track.width + 4, height: 2).fill()
        }
    }
}

final class SlotView: NSView {
    var load: ((URL) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], let url = urls.first else { return false }
        load?(url); return true
    }
}

final class App: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var midi: MIDI!
    var playback = Playback()
    var trimKnobs: [NSSlider] = []
    var trimLabels: [NSTextField] = []
    var masterDown: [Int] = []
    var masterUp: [Int] = []
    var learningMaster = 0
    var heldButtons = Set<String>()
    let masterMapping = NSTextField(labelWithString: "Мастер: кнопки не назначены")
    let connection = NSTextField(labelWithString: "SMC не подключён")
    let event = NSTextField(labelWithString: "MIDI: ожидание")
    let status = NSTextField(labelWithString: "")
    let arm = NSButton(checkboxWithTitle: "Разрешить звук", target: nil, action: nil)
    let masterLabel = NSTextField(labelWithString: "Мастер: 100%")
    var names: [NSTextField] = [], states: [NSTextField] = [], sliders: [NSSlider] = []
    var countdowns: [NSTextField] = []
    var meters: [MeterSliderCell] = []
    var armed = false
    var learningStop = false
    var timer: Timer?
    var saveTimer: Timer?
    var monitor: Any?
    var outputPopup: NSPopUpButton!
    var outputs: [AudioDevice] = []
    let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SMCSampler/slots.json")

    var isSelfTest: Bool {
        CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--self-test-engine")
    }

    func statusText(_ text: String) { status.stringValue = text }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 660), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "SMC Sampler 0.2.0 · 8 семплов"; window.center()
        let root = window.contentView!
        func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ size: CGFloat = 14) {
            let field = NSTextField(labelWithString: text); field.frame = NSRect(x: x, y: y, width: width, height: 28); field.font = .systemFont(ofSize: size); root.addSubview(field)
        }
        label("SMC SAMPLER", 24, 605, 350, 26)
        masterLabel.frame = NSRect(x: 370, y: 610, width: 180, height: 26)
        root.addSubview(masterLabel)
        label("Перетащи файл в слот. Ряд 4: запуск. Ряд 3: стоп. Фейдер: громкость.", 24, 569, 690)
        arm.frame = NSRect(x: 740, y: 608, width: 170, height: 28); arm.target = self; arm.action = #selector(armChanged); root.addSubview(arm)
        let stop = NSButton(title: "СТОП ВСЁ", target: self, action: #selector(stopAll)); stop.frame = NSRect(x: 920, y: 604, width: 170, height: 36); root.addSubview(stop)
        let less = NSButton(title: "−5%", target: self, action: #selector(masterLess))
        less.frame = NSRect(x: 550, y: 604, width: 75, height: 32); root.addSubview(less)
        let more = NSButton(title: "+5%", target: self, action: #selector(masterMore))
        more.frame = NSRect(x: 630, y: 604, width: 75, height: 32); root.addSubview(more)
        if let stored = UserDefaults.standard.array(forKey: "trimDB") as? [Float], stored.count == 8 {
            playback.trims = stored.map { min(0, max(-60, $0.isFinite ? $0 : 0)) }
        }
        if let stored = UserDefaults.standard.array(forKey: "levels") as? [Float], stored.count == 8 {
            playback.levels = stored.map { min(1, max(0, $0.isFinite ? $0 : 0)) }
        }
        masterDown = UserDefaults.standard.array(forKey: "masterDown") as? [Int] ?? []
        masterUp = UserDefaults.standard.array(forKey: "masterUp") as? [Int] ?? []
        for i in 0..<8 {
            let card = SlotView(frame: NSRect(x: 24 + i * 135, y: 152, width: 127, height: 400))
            card.wantsLayer = true; card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor; card.layer?.cornerRadius = 10
            card.load = { [weak self] url in self?.load(url, i) }; root.addSubview(card)
            let title = NSTextField(labelWithString: "\(i + 1)"); title.frame = NSRect(x: 12, y: 356, width: 40, height: 32); title.font = .boldSystemFont(ofSize: 25); card.addSubview(title)
            let trim = NSSlider(value: Double(playback.trims[i]), minValue: -60, maxValue: 0, target: self, action: #selector(trimChanged(_:)))
            trim.sliderType = .circular; trim.tag = i
            trim.frame = NSRect(x: 77, y: 346, width: 38, height: 38)
            trim.toolTip = "TRIM: уровень файла до фейдера, −60…0 dB"
            card.addSubview(trim); trimKnobs.append(trim)
            let trimText = NSTextField(labelWithString: String(format: "TRIM %.0f dB", playback.trims[i]))
            trimText.frame = NSRect(x: 10, y: 326, width: 110, height: 20); trimText.alignment = .center
            trimText.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            card.addSubview(trimText); trimLabels.append(trimText)
            let name = NSTextField(wrappingLabelWithString: "Перетащи трек"); name.frame = NSRect(x: 12, y: 286, width: 105, height: 40)
            name.toolTip = "Имя файла в слоте"; card.addSubview(name); names.append(name)
            let countdown = NSTextField(labelWithString: "− --:--")
            countdown.frame = NSRect(x: 10, y: 255, width: 112, height: 30)
            countdown.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
            countdown.alignment = .center; card.addSubview(countdown); countdowns.append(countdown)
            let slider = NSSlider(value: Double(playback.levels[i]), minValue: 0, maxValue: 1, target: self, action: #selector(volumeChanged(_:)))
            slider.cell = MeterSliderCell(); slider.target = self; slider.action = #selector(volumeChanged(_:)); slider.tag = i; slider.isVertical = true
            meters.append(slider.cell as! MeterSliderCell); slider.frame = NSRect(x: 48, y: 84, width: 28, height: 168); card.addSubview(slider); sliders.append(slider)
            let state = NSTextField(labelWithString: "0% · стоп"); state.frame = NSRect(x: 10, y: 61, width: 112, height: 20); state.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); card.addSubview(state); states.append(state)
            let play = NSButton(title: "▶ С начала", target: self, action: #selector(playClicked(_:)))
            play.tag = i; play.frame = NSRect(x: 5, y: 34, width: 88, height: 26); play.font = .systemFont(ofSize: 10.5)
            play.toolTip = "Запуск с начала"; card.addSubview(play)
            let stopSlot = NSButton(title: "■", target: self, action: #selector(stopClicked(_:)))
            stopSlot.tag = i; stopSlot.frame = NSRect(x: 95, y: 34, width: 27, height: 26)
            stopSlot.toolTip = "Стоп и возврат в начало"; card.addSubview(stopSlot)
            let choose = NSButton(title: "Файл…", target: self, action: #selector(chooseFile(_:))); choose.tag = i; choose.frame = NSRect(x: 5, y: 4, width: 117, height: 26); card.addSubview(choose)
        }
        status.frame = NSRect(x: 24, y: 122, width: 720, height: 22)
        status.font = .systemFont(ofSize: 12, weight: .medium)
        root.addSubview(status)
        connection.frame = NSRect(x: 24, y: 96, width: 720, height: 22); root.addSubview(connection)
        event.frame = NSRect(x: 24, y: 70, width: 720, height: 22)
        event.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); event.textColor = .secondaryLabelColor
        root.addSubview(event)
        masterMapping.frame = NSRect(x: 24, y: 42, width: 600, height: 22); root.addSubview(masterMapping)
        let outputTitle = NSTextField(labelWithString: "Выход:"); outputTitle.frame = NSRect(x: 640, y: 42, width: 55, height: 22); root.addSubview(outputTitle)
        outputPopup = NSPopUpButton(frame: NSRect(x: 700, y: 38, width: 240, height: 26))
        outputPopup.target = self; outputPopup.action = #selector(outputChanged); root.addSubview(outputPopup)
        label("Esc или Пробел — стоп всё · 1–8 — запуск слота", 24, 12, 600, 11)
        let learn = NSButton(title: "Назначить кнопку «Стоп всё»…", target: self, action: #selector(learnStop))
        learn.frame = NSRect(x: 760, y: 118, width: 330, height: 26); root.addSubview(learn)
        let learnMasterButton = NSButton(title: "Назначить стрелки мастера…", target: self, action: #selector(learnMaster))
        learnMasterButton.frame = NSRect(x: 760, y: 92, width: 330, height: 26); root.addSubview(learnMasterButton)
        updateMasterMapping()
        var startupNote = ""
        if let data = try? Data(contentsOf: config), let stored = try? JSONDecoder().decode([String].self, from: data) {
            for (i, path) in stored.prefix(8).enumerated() where !path.isEmpty {
                if !load(URL(fileURLWithPath: path), i, save: false) {
                    startupNote = "Часть файлов не открылась: проверь пути в слотах"
                }
            }
        }
        if isSelfTest {
            selfTest()
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--render-ui"), CommandLine.arguments.count > flag + 1 {
            outputs = outputDevices().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            updateOutputPopup(selected: outputs.first { $0.uid == (UserDefaults.standard.string(forKey: "outputUID") ?? "") })
            renderWindow(to: CommandLine.arguments[flag + 1])
            return
        }
        outputs = outputDevices().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let storedUID = UserDefaults.standard.string(forKey: "outputUID") ?? ""
        let chosen = outputs.first { $0.uid == storedUID }
        do {
            try playback.setOutput(chosen)
            try playback.start()
            if startupNote.isEmpty { startupNote = "Выход: " + (chosen?.name ?? "системный") }
        } catch {
            startupNote = "Аудио: \(error.localizedDescription)"
        }
        updateOutputPopup(selected: chosen)
        if !startupNote.isEmpty { statusText(startupNote) }
        midi = MIDI()
        midi.receive = { [weak self] bytes in self?.received(bytes) }
        midi.connection = { [weak self] text in
            guard let self = self else { return }; self.connection.stringValue = text
            for i in 0..<8 { self.midi.lamp(i, self.playback.running(i)); self.midi.lamp(i, self.playback.loaded(i), loaded: true) }
        }
        midi.connect()
        playback.onEnd = { [weak self] i in self?.midi?.lamp(i, false); self?.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.refresh() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.keyPressed(event) ?? event
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    // Draws the window into a PNG without showing it or touching audio.
    func renderWindow(to path: String) {
        guard let view = window.contentView else { return }
        window.appearance = NSAppearance(named: .aqua)
        for case let card as SlotView in view.subviews { card.layer?.backgroundColor = NSColor(calibratedWhite: 0.95, alpha: 1).cgColor }
        view.needsDisplay = true
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds
        if let rep = view.bitmapImageRepForCachingDisplay(in: bounds) {
            view.cacheDisplay(in: bounds, to: rep)
            let image = NSImage(size: bounds.size)
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: bounds.size).fill()
            rep.draw(in: NSRect(origin: .zero, size: bounds.size))
            image.unlockFocus()
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
        NSApp.terminate(nil)
    }

    func keyPressed(_ event: NSEvent) -> NSEvent? {
        guard window.attachedSheet == nil, !event.isARepeat else { return event }
        if event.keyCode == 53 || event.keyCode == 49 { stopAll(); return nil }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        if modifiers.isEmpty, let character = event.charactersIgnoringModifiers, let number = Int(character), (1...8).contains(number) {
            trigger(number - 1); return nil
        }
        return event
    }

    func updateOutputPopup(selected: AudioDevice?) {
        outputPopup.removeAllItems()
        outputPopup.addItem(withTitle: "Система (по умолчанию)")
        for device in outputs { outputPopup.addItem(withTitle: device.name) }
        if let selected, let index = outputs.firstIndex(where: { $0.uid == selected.uid }) {
            outputPopup.selectItem(at: index + 1)
        } else {
            outputPopup.selectItem(at: 0)
        }
    }

    @objc func outputChanged() {
        let index = outputPopup.indexOfSelectedItem
        applyOutput(index >= 1 ? outputs[index - 1] : nil)
    }

    func applyOutput(_ device: AudioDevice?) {
        stopAll()
        do {
            try playback.setOutput(device)
            UserDefaults.standard.set(device?.uid ?? "", forKey: "outputUID")
            statusText("Выход: " + (device?.name ?? "системный"))
        } catch {
            statusText("Выход: \(error.localizedDescription)")
        }
        refresh()
    }

    @discardableResult
    func load(_ url: URL, _ i: Int, save: Bool = true) -> Bool {
        do {
            try playback.load(url, i)
        } catch {
            statusText("Слот \(i + 1): \(error.localizedDescription)")
            return false
        }
        names[i].stringValue = url.lastPathComponent
        names[i].toolTip = url.lastPathComponent
        midi?.lamp(i, false)
        midi?.lamp(i, true, loaded: true)
        if save {
            UserDefaults.standard.set(playback.trims, forKey: "trimDB")
            let paths = (0..<8).map { $0 == i ? url.path : storedPath($0) }
            do {
                try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(paths).write(to: config, options: .atomic)
            } catch {
                statusText("Слот \(i + 1): не удалось сохранить путь: \(error.localizedDescription)")
                return false
            }
        }
        statusText("Слот \(i + 1): \(url.lastPathComponent)")
        refresh()
        return true
    }

    func storedPath(_ i: Int) -> String {
        if let data = try? Data(contentsOf: config), let stored = try? JSONDecoder().decode([String].self, from: data), stored.count > i {
            return stored[i]
        }
        return ""
    }

    @objc func chooseFile(_ sender: NSButton) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] result in
            if result == .OK, let url = panel.url { self?.load(url, sender.tag) }
        }
    }

    @objc func learnStop() { learningMaster = 0; learningStop = true; armed = false; arm.state = .off; stopAll(); statusText("Нажми нижнюю кнопку «Пауза»: сохраню её как Стоп всё. Звук заблокирован.") }
    @objc func armChanged() {
        armed = arm.state == .on
        if armed { statusText("Звук разрешён") } else { stopAll(); statusText("Звук заблокирован") }
    }
    func stopSlot(_ i: Int) {
        playback.stop(i); midi?.lamp(i, false)
        statusText("Слот \(i + 1): стоп"); refresh()
    }
    @objc func stopAll() {
        for i in 0..<8 { playback.stop(i); midi?.lamp(i, false) }
        statusText("Стоп всё: все слоты остановлены"); refresh()
    }
    @objc func stopClicked(_ sender: NSButton) { stopSlot(sender.tag) }
    @objc func volumeChanged(_ sender: NSSlider) { setVolume(sender.tag, sender.floatValue) }
    func setVolume(_ i: Int, _ value: Float) {
        playback.setLevel(i, value)
        sliders[i].floatValue = playback.levels[i]
        scheduleLevelsSave()
    }
    func scheduleLevelsSave() {
        guard !isSelfTest else { return }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            UserDefaults.standard.set(self?.playback.levels ?? [], forKey: "levels")
        }
    }
    func setMaster(_ value: Float) {
        playback.setMaster(value)
        masterLabel.stringValue = "Мастер: \(Int((playback.master * 100).rounded()))%"
    }
    @objc func masterLess() { setMaster(playback.master - 0.05) }
    @objc func masterMore() { setMaster(playback.master + 0.05) }
    @objc func trimChanged(_ sender: NSSlider) { setTrim(sender.tag, sender.floatValue) }
    func setTrim(_ i: Int, _ value: Float) {
        playback.setTrim(i, value)
        trimKnobs[i].floatValue = playback.trims[i]
        trimLabels[i].stringValue = String(format: "TRIM %.0f dB", playback.trims[i])
        if !isSelfTest { UserDefaults.standard.set(playback.trims, forKey: "trimDB") }
    }
    func updateMasterMapping() {
        masterMapping.stringValue = masterDown.count == 2 && masterUp.count == 2 ? "Мастер: стрелки −5% / +5% назначены" : "Мастер: назначь нижние стрелки кнопкой справа"
    }
    @objc func learnMaster() {
        learningStop = false; learningMaster = 1
        armed = false; arm.state = .off; stopAll()
        statusText("Нажми нижнюю стрелку ВНИЗ (мастер −5%)")
    }
    @objc func playClicked(_ sender: NSButton) { trigger(sender.tag) }
    func trigger(_ i: Int) {
        guard armed else { statusText("Слот \(i + 1): запуск заблокирован. В перерыве включи «Разрешить звук»."); return }
        if let problem = playback.trigger(i) { statusText("Слот \(i + 1): \(problem)"); refresh(); return }
        midi?.lamp(i, true)
        statusText("Слот \(i + 1): играет")
        refresh()
    }
    func received(_ b: [UInt8]) {
        guard b.count == 3 else { return }
        event.stringValue = "MIDI: " + b.map { String(format: "%02X", $0) }.joined(separator: " ")
        let type = b[0] & 0xF0, channel = Int(b[0] & 15)
        let eligible = (type == 0x90 || type == 0xB0) && b[2] > 0 && !(type == 0xB0 && (30...47).contains(b[1]))
        let command = [Int(b[0]), Int(b[1])]
        let buttonKey = "\(b[0] & 15):\(type == 0x80 ? 0x90 : type):\(b[1])"
        let released = type == 0x80 || b[2] == 0
        if released { heldButtons.remove(buttonKey) }
        let freshPress = eligible && !heldButtons.contains(buttonKey)
        if eligible { heldButtons.insert(buttonKey) }
        if learningMaster > 0 && freshPress {
            let reserved = channel == 0 && ((type == 0xB0 && (b[1] == 53 || (70...97).contains(b[1]))) || (type == 0x90 && b[1] < 32))
            let stop = UserDefaults.standard.array(forKey: "stopCommand") as? [Int] ?? []
            guard !reserved && command != stop else { statusText("Эта кнопка занята. Нужна нижняя стрелка."); return }
            if learningMaster == 1 {
                masterDown = command; learningMaster = 2
                statusText("Теперь нажми нижнюю стрелку ВВЕРХ (мастер +5%)")
            } else {
                guard command != masterDown else { statusText("Нужна другая кнопка: стрелка ВВЕРХ"); return }
                masterUp = command; learningMaster = 0
                UserDefaults.standard.set(masterDown, forKey: "masterDown")
                UserDefaults.standard.set(masterUp, forKey: "masterUp")
                updateMasterMapping(); statusText("Стрелки мастера сохранены: −5% / +5%")
            }
            return
        }
        if command == masterDown || command == masterUp {
            if freshPress { setMaster(playback.master + (command == masterDown ? -0.05 : 0.05)) }
            return
        }
        if learningStop && eligible {
            UserDefaults.standard.set([Int(b[0]), Int(b[1])], forKey: "stopCommand")
            learningStop = false; statusText("Кнопка «Стоп всё» сохранена"); return
        }
        if let stop = UserDefaults.standard.array(forKey: "stopCommand") as? [Int], stop == [Int(b[0]), Int(b[1])], b[2] > 0 { stopAll(); return }
        if type == 0xB0 && channel == 0 {
            if (30...37).contains(b[1]) {
                let i = Int(b[1]) - 30
                if b[2] == 127 { setTrim(i, playback.trims[i] + 1) }
                else if b[2] == 0 { setTrim(i, playback.trims[i] - 1) }
                return
            }
            if b[1] == 53 && b[2] > 0 { stopAll(); return }
            if (40...47).contains(b[1]) { setVolume(Int(b[1]) - 40, Float(b[2]) / 127) }
            if (90...97).contains(b[1]) && b[2] > 0 { stopSlot(Int(b[1]) - 90) }
            if (70...77).contains(b[1]) && b[2] > 0 { trigger(Int(b[1]) - 70) }
        } else if (type == 0x90 || type == 0x80) && channel == 0 && (0...7).contains(b[1]) {
            let i = Int(b[1])
            if type == 0x90 && b[2] > 0 { stopSlot(i) }
        } else if type == 0x90 && channel == 0 && (24...31).contains(b[1]) && b[2] > 0 {
            trigger(Int(b[1]) - 24)
        } else if type == 0xE0 && channel < 8 {
            setVolume(channel, Float(Int(b[1]) + (Int(b[2]) << 7)) / 16383)
        }
    }
    func refresh() {
        for i in 0..<8 {
            let playing = playback.running(i)
            let duration = playback.duration(i)
            if duration > 0 {
                let position = playback.finished.contains(i) ? duration : playback.position(i)
                countdowns[i].stringValue = "− " + timeRemaining(duration, position)
                countdowns[i].textColor = playing && duration - position <= 10 ? .systemOrange : .labelColor
            } else {
                countdowns[i].stringValue = "− --:--"
            }
            if playing {
                let (power, peak) = playback.meter(i)
                meters[i].update(power: power, peak: peak)
            } else {
                meters[i].update(power: -160, peak: -160)
            }
            states[i].stringValue = "\(Int(playback.levels[i] * 100))% · " + (playing ? "играет" : "стоп")
            states[i].textColor = playing ? .systemGreen : .secondaryLabelColor
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        for i in 0..<8 { playback.stop(i) }
        if !isSelfTest { UserDefaults.standard.set(playback.levels, forKey: "levels") }
        for i in 0..<8 { midi?.lamp(i, false, loaded: true) }
        playback.shutdown()
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    // Silent checks: no audio is decoded from disk and no engine is started.
    func selfTest() {
        received([0xB0, 40, 127]); assert(playback.levels[0] == 1)
        received([0xB0, 47, 0]); assert(playback.levels[7] == 0)
        received([0xE7, 127, 127]); assert(playback.levels[7] == 1)
        received([0xB0, 70, 127]); assert(!armed && status.stringValue.contains("заблокирован"))
        received([0x90, 31, 127]); assert(status.stringValue.contains("Слот 8"))
        received([0xB0, 53, 127]); assert((0..<8).allSatisfy { !playback.running($0) })
        for i in 0..<8 {
            received([0xB0, UInt8(90 + i), 127]); assert(status.stringValue == "Слот \(i + 1): стоп")
            received([0x90, UInt8(i), 127]); assert(status.stringValue == "Слот \(i + 1): стоп")
            received([0xB0, UInt8(90 + i), 0]); assert(!playback.running(i))
            received([0x90, UInt8(i), 0]); assert(!playback.running(i))
        }
        setMaster(0.5)
        masterDown = [0xB0, 110]; masterUp = [0xB0, 111]
        received([0xB0, 111, 127]); assert(abs(playback.master - 0.55) < 0.0001)
        received([0xB0, 111, 127]); assert(abs(playback.master - 0.55) < 0.0001)
        received([0xB0, 111, 0]); assert(abs(playback.master - 0.55) < 0.0001)
        received([0xB0, 110, 127]); assert(abs(playback.master - 0.5) < 0.0001)
        setTrim(0, -12)
        received([0xB0, 30, 127]); assert(playback.trims[0] == -11 && abs(playback.master - 0.5) < 0.0001)
        received([0xB0, 30, 0]); assert(playback.trims[0] == -12)
        setMaster(2); assert(playback.master == 1)
        setMaster(-1); assert(playback.master == 0)
        setMaster(0.5)
        for i in 0..<8 { assert(abs(playback.gain(i) - playback.levels[i] * playback.master * pow(10, playback.trims[i] / 20)) < 0.0001) }
        assert(timeRemaining(61.2, 0) == "01:02")
        assert(timeRemaining(61.2, 61.1) == "00:01")
        assert(timeRemaining(61.2, 62) == "00:00")
        refresh(); assert(meters.allSatisfy { $0.power == -160 })
        let devices = outputDevices()
        assert(!devices.isEmpty)
        do {
            let mono = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            let silent = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 4800)!
            silent.frameLength = 4800
            memset(silent.floatChannelData![0], 0, Int(silent.frameLength) * MemoryLayout<Float>.size)
            let converted = try Playback.canonicalize(silent)
            assert(converted.format.sampleRate == 44100 && converted.format.channelCount == 2)
            assert(abs(Playback.seconds(converted) - 0.1) < 0.02)
        } catch { assertionFailure("canonicalize: \(error)") }
        print("PASS: countdown rounding/end and idle meters; master direction, limits, gain product; individual stop User/Mackie, release ignored; CC faders, Mackie pitch bend, both trigger maps, playback lock, stop-all dispatch; 48 kHz mono → 44.1 kHz stereo conversion; \(devices.count) output device(s): \(devices.map(\.name).joined(separator: ", "))")
        NSApp.terminate(nil)
    }
}

// Silent engine probe: schedules half a second of digital silence and checks
// that the timeline advances and that stop resets it. Run with --self-test-engine.
func runEngineTest() {
    let devices = outputDevices()
    var routes: [AudioDevice?] = [nil]
    routes.append(contentsOf: devices.map { Optional($0) })
    for route in routes {
        let label = route?.name ?? "система по умолчанию"
        let playback = Playback()
        do {
            try playback.setOutput(route)
            try playback.start()
        } catch {
            print("SKIP \(label): \(error.localizedDescription)")
            playback.shutdown()
            continue
        }
        guard let silent = AVAudioPCMBuffer(pcmFormat: Playback.canonical, frameCapacity: 22050) else {
            print("FAIL: could not allocate buffer"); exit(1)
        }
        silent.frameLength = 22050
        for channel in 0..<Int(Playback.canonical.channelCount) {
            memset(silent.floatChannelData![channel], 0, Int(silent.frameLength) * MemoryLayout<Float>.size)
        }
        playback.inject(0, silent)
        guard playback.trigger(0) == nil else { print("FAIL \(label): trigger refused"); exit(1) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let position = playback.position(0)
        guard playback.running(0), position > 0.15 else {
            print("FAIL \(label): position \(position), running \(playback.running(0))"); exit(1)
        }
        playback.stop(0)
        guard playback.position(0) == 0, !playback.running(0) else { print("FAIL \(label): stop did not reset"); exit(1) }
        guard playback.tapCount > 0 else { print("FAIL \(label): meter tap never fired"); exit(1) }
        print("OK \(label): silent buffer advanced \(String(format: "%.2f", position)) s, meter taps \(playback.tapCount)")
        playback.shutdown()
    }
    print("PASS engine: silent playback and metering on \(routes.count) route(s), stop resets to zero")
    exit(0)
}

if CommandLine.arguments.contains("--self-test-engine") {
    runEngineTest()
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = App()
    app.delegate = delegate
    app.run()
}
