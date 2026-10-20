// SMC Sampler: eight independent audio slots with CoreMIDI feedback.
// Build with ./build.sh. Playback is locked on every launch.
import Cocoa
import AVFoundation
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
        guard fraction > 0 else { return }
        let height = track.height * fraction
        let fill = NSRect(x: track.minX, y: flipped ? track.maxY - height : track.minY, width: track.width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).addClip()
        let gradient = NSGradient(colors: [.systemGreen, .systemYellow, .systemRed])!
        NSBezierPath(rect: fill).addClip()
        gradient.draw(in: track, angle: flipped ? -90 : 90)
        NSGraphicsContext.restoreGraphicsState()
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

final class App: NSObject, NSApplicationDelegate, AVAudioPlayerDelegate {
    var window: NSWindow!
    var midi: MIDI!
    var players = [AVAudioPlayer?](repeating: nil, count: 8)
    var paths = [String](repeating: "", count: 8)
    var trims = [Float](repeating: 0, count: 8)
    var trimKnobs: [NSSlider] = []
    var trimLabels: [NSTextField] = []
    var masterDown: [Int] = []
    var masterUp: [Int] = []
    var learningMaster = 0
    var heldButtons = Set<String>()
    let masterMapping = NSTextField(labelWithString: "Мастер: кнопки не назначены")
    var levels = [Float](repeating: 0, count: 8)
    var names: [NSTextField] = [], states: [NSTextField] = [], sliders: [NSSlider] = []
    let connection = NSTextField(labelWithString: "SMC не подключён")
    let event = NSTextField(labelWithString: "MIDI: ожидание")
    let arm = NSButton(checkboxWithTitle: "Разрешить звук", target: nil, action: nil)
    var master: Float = 1
    let masterLabel = NSTextField(labelWithString: "Мастер: 100%")
    var countdowns: [NSTextField] = []
    var meters: [MeterSliderCell] = []
    var finished = Set<Int>()
    var armed = false
    var learningStop = false
    var timer: Timer?
    let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SMCSampler/slots.json")
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 620), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "SMC Sampler · 8 семплов"; window.center()
        let root = window.contentView!
        func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ size: CGFloat = 14) {
            let field = NSTextField(labelWithString: text); field.frame = NSRect(x: x, y: y, width: width, height: 28); field.font = .systemFont(ofSize: size); root.addSubview(field)
        }
        label("SMC SAMPLER", 24, 565, 350, 26)
        masterLabel.frame = NSRect(x: 370, y: 570, width: 180, height: 26)
        root.addSubview(masterLabel)
        label("Перетащи файл в слот. Ряд 4: запуск. Ряд 3: стоп. Фейдер: громкость.", 24, 529, 1050)
        arm.frame = NSRect(x: 740, y: 570, width: 170, height: 28); arm.target = self; arm.action = #selector(armChanged); root.addSubview(arm)
        let stop = NSButton(title: "СТОП ВСЁ", target: self, action: #selector(stopAll)); stop.frame = NSRect(x: 920, y: 566, width: 170, height: 36); root.addSubview(stop)
        let less = NSButton(title: "−5%", target: self, action: #selector(masterLess))
        less.frame = NSRect(x: 550, y: 566, width: 75, height: 32); root.addSubview(less)
        let more = NSButton(title: "+5%", target: self, action: #selector(masterMore))
        more.frame = NSRect(x: 630, y: 566, width: 75, height: 32); root.addSubview(more)
        if let stored = UserDefaults.standard.array(forKey: "trimDB") as? [Float], stored.count == 8 {
            trims = stored.map { min(0, max(-60, $0.isFinite ? $0 : 0)) }
        }
        masterDown = UserDefaults.standard.array(forKey: "masterDown") as? [Int] ?? []
        masterUp = UserDefaults.standard.array(forKey: "masterUp") as? [Int] ?? []
        for i in 0..<8 {
            let card = SlotView(frame: NSRect(x: 24 + i * 135, y: 112, width: 127, height: 400))
            card.wantsLayer = true; card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor; card.layer?.cornerRadius = 10
            card.load = { [weak self] url in self?.load(url, i) }; root.addSubview(card)
            let title = NSTextField(labelWithString: "\(i + 1)"); title.frame = NSRect(x: 12, y: 356, width: 40, height: 32); title.font = .boldSystemFont(ofSize: 25); card.addSubview(title)
            let trim = NSSlider(value: Double(trims[i]), minValue: -60, maxValue: 0, target: self, action: #selector(trimChanged(_:)))
            trim.sliderType = .circular; trim.tag = i
            trim.frame = NSRect(x: 77, y: 346, width: 38, height: 38)
            trim.toolTip = "TRIM: уровень файла до фейдера, −60…0 dB"
            card.addSubview(trim); trimKnobs.append(trim)
            let trimText = NSTextField(labelWithString: String(format: "TRIM %.0f dB", trims[i]))
            trimText.frame = NSRect(x: 10, y: 326, width: 110, height: 20); trimText.alignment = .center
            trimText.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            card.addSubview(trimText); trimLabels.append(trimText)
            let name = NSTextField(wrappingLabelWithString: "Перетащи трек"); name.frame = NSRect(x: 12, y: 286, width: 105, height: 40); card.addSubview(name); names.append(name)
            let countdown = NSTextField(labelWithString: "− --:--")
            countdown.frame = NSRect(x: 10, y: 255, width: 112, height: 30)
            countdown.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
            countdown.alignment = .center; card.addSubview(countdown); countdowns.append(countdown)
            let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(volumeChanged(_:))); slider.cell = MeterSliderCell(); slider.target = self; slider.action = #selector(volumeChanged(_:)); slider.minValue = 0; slider.maxValue = 1; slider.doubleValue = 0; slider.tag = i; slider.isVertical = true; meters.append(slider.cell as! MeterSliderCell); slider.frame = NSRect(x: 48, y: 84, width: 28, height: 168); card.addSubview(slider); sliders.append(slider)
            let state = NSTextField(labelWithString: "0% · стоп"); state.frame = NSRect(x: 10, y: 61, width: 112, height: 20); state.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); card.addSubview(state); states.append(state)
            let play = NSButton(title: "▶ С начала", target: self, action: #selector(playClicked(_:))); play.tag = i; play.frame = NSRect(x: 5, y: 30, width: 117, height: 28); card.addSubview(play)
            let choose = NSButton(title: "Файл…", target: self, action: #selector(chooseFile(_:))); choose.tag = i; choose.frame = NSRect(x: 5, y: 2, width: 117, height: 28); card.addSubview(choose)
        }
        let learn = NSButton(title: "Назначить кнопку «Стоп всё»…", target: self, action: #selector(learnStop))
        learn.frame = NSRect(x: 760, y: 72, width: 330, height: 26); root.addSubview(learn)
        connection.frame = NSRect(x: 24, y: 72, width: 730, height: 24); root.addSubview(connection)
        let learnMasterButton = NSButton(title: "Назначить стрелки мастера…", target: self, action: #selector(learnMaster))
        learnMasterButton.frame = NSRect(x: 760, y: 40, width: 330, height: 26); root.addSubview(learnMasterButton)
        masterMapping.frame = NSRect(x: 24, y: 17, width: 700, height: 20); root.addSubview(masterMapping)
        updateMasterMapping()
        event.frame = NSRect(x: 24, y: 42, width: 730, height: 24); root.addSubview(event)
        label("Выход: системное устройство macOS", 760, 8, 330, 11)
        if let data = try? Data(contentsOf: config), let stored = try? JSONDecoder().decode([String].self, from: data) {
            for (i, path) in stored.prefix(8).enumerated() where !path.isEmpty { load(URL(fileURLWithPath: path), i, save: false) }
        }
        if CommandLine.arguments.contains("--self-test") {
            received([0xB0, 40, 127]); assert(levels[0] == 1)
            received([0xB0, 47, 0]); assert(levels[7] == 0)
            received([0xE7, 127, 127]); assert(levels[7] == 1)
            received([0xB0, 70, 127]); assert(!armed && event.stringValue.contains("заблокирован"))
            received([0x90, 31, 127]); assert(event.stringValue.contains("Слот 8"))
            received([0xB0, 53, 127]); assert(players.allSatisfy { $0?.isPlaying != true })
            for i in 0..<8 {
                received([0xB0, UInt8(90 + i), 127]); assert(event.stringValue == "Слот \(i + 1): стоп")
                received([0x90, UInt8(i), 127]); assert(event.stringValue == "Слот \(i + 1): стоп")
                received([0xB0, UInt8(90 + i), 0]); assert(!event.stringValue.contains(": стоп"))
                received([0x90, UInt8(i), 0]); assert(!event.stringValue.contains(": стоп"))
            }
            setMaster(0.5)
            masterDown = [0xB0, 110]; masterUp = [0xB0, 111]
            received([0xB0, 111, 127]); assert(abs(master - 0.55) < 0.0001)
            received([0xB0, 111, 127]); assert(abs(master - 0.55) < 0.0001)
            received([0xB0, 111, 0]); assert(abs(master - 0.55) < 0.0001)
            received([0xB0, 110, 127]); assert(abs(master - 0.5) < 0.0001)
            setTrim(0, -12)
            received([0xB0, 30, 127]); assert(trims[0] == -11 && abs(master - 0.5) < 0.0001)
            received([0xB0, 30, 0]); assert(trims[0] == -12)
            setMaster(2); assert(master == 1)
            setMaster(-1); assert(master == 0)
            setMaster(0.5)
            for i in 0..<8 { if let player = players[i] { assert(abs(player.volume - levels[i] * master * pow(10, trims[i] / 20)) < 0.0001) } }
            assert(timeRemaining(61.2, 0) == "01:02")
            assert(timeRemaining(61.2, 61.1) == "00:01")
            assert(timeRemaining(61.2, 62) == "00:00")
            refresh(); assert(meters.allSatisfy { $0.power == -160 })
            print("PASS: countdown rounding/end and idle meters; master direction, limits, gain product; individual stop User/Mackie, release ignored; CC faders, Mackie pitch bend, both trigger maps, playback lock, stop-all dispatch")
            NSApp.terminate(nil)
            return
        }
        midi = MIDI()
        midi.receive = { [weak self] bytes in self?.received(bytes) }
        midi.connection = { [weak self] text in
            guard let self = self else { return }; self.connection.stringValue = text
            for i in 0..<8 { self.midi.lamp(i, self.players[i]?.isPlaying == true); self.midi.lamp(i, self.players[i] != nil, loaded: true) }
        }
        midi.connect()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.refresh() }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func load(_ url: URL, _ i: Int, save: Bool = true) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self; player.isMeteringEnabled = true; player.volume = levels[i] * master * pow(10, trims[i] / 20)
            players[i]?.stop(); finished.remove(i); players[i] = player; paths[i] = url.path
            names[i].stringValue = url.lastPathComponent
            midi?.lamp(i, false)
            midi?.lamp(i, true, loaded: true)
            if save {
                try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(paths).write(to: config, options: .atomic)
            }
        } catch { event.stringValue = "Слот \(i + 1): \(error.localizedDescription)" }
    }
    @objc func chooseFile(_ sender: NSButton) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] result in
            if result == .OK, let url = panel.url { self?.load(url, sender.tag) }
        }
    }
    @objc func learnStop() { learningMaster = 0; learningStop = true; armed = false; arm.state = .off; stopAll(); event.stringValue = "Нажми нижнюю кнопку «Пауза»: сохраню её как Стоп всё. Звук заблокирован." }
    @objc func armChanged() { armed = arm.state == .on; if !armed { stopAll() } }
    func stopSlot(_ i: Int) {
        finished.remove(i); players[i]?.stop(); players[i]?.currentTime = 0; midi?.lamp(i, false)
        event.stringValue = "Слот \(i + 1): стоп"; refresh()
    }
    @objc func stopAll() { for i in 0..<8 { stopSlot(i) } }
    @objc func volumeChanged(_ sender: NSSlider) { setVolume(sender.tag, sender.floatValue) }
    func setVolume(_ i: Int, _ value: Float) { levels[i] = value; sliders[i].floatValue = value; players[i]?.volume = value * master * pow(10, trims[i] / 20) }
    func setMaster(_ value: Float) {
        master = min(1, max(0, value))
        masterLabel.stringValue = "Мастер: \(Int((master * 100).rounded()))%"
        for i in 0..<8 { players[i]?.volume = levels[i] * master * pow(10, trims[i] / 20) }
    }
    @objc func masterLess() { setMaster(master - 0.05) }
    @objc func masterMore() { setMaster(master + 0.05) }
    @objc func trimChanged(_ sender: NSSlider) { setTrim(sender.tag, sender.floatValue) }
    func setTrim(_ i: Int, _ value: Float) {
        trims[i] = min(0, max(-60, value))
        trimKnobs[i].floatValue = trims[i]
        trimLabels[i].stringValue = String(format: "TRIM %.0f dB", trims[i])
        players[i]?.volume = levels[i] * master * pow(10, trims[i] / 20)
        if !CommandLine.arguments.contains("--self-test") { UserDefaults.standard.set(trims, forKey: "trimDB") }
    }
    func updateMasterMapping() {
        masterMapping.stringValue = masterDown.count == 2 && masterUp.count == 2 ? "Мастер: стрелки −5% / +5% назначены" : "Мастер: назначь нижние стрелки кнопкой справа"
    }
    @objc func learnMaster() {
        learningStop = false; learningMaster = 1
        armed = false; arm.state = .off; stopAll()
        event.stringValue = "Нажми нижнюю стрелку ВНИЗ (мастер −5%)"
    }
    @objc func playClicked(_ sender: NSButton) { trigger(sender.tag) }
    func trigger(_ i: Int) {
        guard armed else { event.stringValue = "Слот \(i + 1): запуск заблокирован. В перерыве включи «Разрешить звук»."; return }
        guard let player = players[i] else { event.stringValue = "Слот \(i + 1): сначала добавь файл"; return }
        finished.remove(i); player.stop(); player.currentTime = 0
        let started = player.play(); midi.lamp(i, started)
        if !started { event.stringValue = "Слот \(i + 1): не удалось начать воспроизведение" }
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
            guard !reserved && command != stop else { event.stringValue = "Эта кнопка занята. Нужна нижняя стрелка."; return }
            if learningMaster == 1 {
                masterDown = command; learningMaster = 2
                event.stringValue = "Теперь нажми нижнюю стрелку ВВЕРХ (мастер +5%)"
            } else {
                guard command != masterDown else { event.stringValue = "Нужна другая кнопка: стрелка ВВЕРХ"; return }
                masterUp = command; learningMaster = 0
                UserDefaults.standard.set(masterDown, forKey: "masterDown")
                UserDefaults.standard.set(masterUp, forKey: "masterUp")
                updateMasterMapping(); event.stringValue = "Стрелки мастера сохранены: −5% / +5%"
            }
            return
        }
        if command == masterDown || command == masterUp {
            if freshPress { setMaster(master + (command == masterDown ? -0.05 : 0.05)) }
            return
        }
        if learningStop && eligible {
            UserDefaults.standard.set([Int(b[0]), Int(b[1])], forKey: "stopCommand")
            learningStop = false; event.stringValue = "Кнопка «Стоп всё» сохранена"; return
        }
        if let stop = UserDefaults.standard.array(forKey: "stopCommand") as? [Int], stop == [Int(b[0]), Int(b[1])], b[2] > 0 { stopAll(); return }
        if type == 0xB0 && channel == 0 {
            if (30...37).contains(b[1]) {
                let i = Int(b[1]) - 30
                if b[2] == 127 { setTrim(i, trims[i] + 1) }
                else if b[2] == 0 { setTrim(i, trims[i] - 1) }
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
            let playing = players[i]?.isPlaying == true
            if let player = players[i] {
                let position = finished.contains(i) ? player.duration : player.currentTime
                countdowns[i].stringValue = "− " + timeRemaining(player.duration, position)
                countdowns[i].textColor = playing && player.duration - position <= 10 ? .systemOrange : .labelColor
                if playing {
                    player.updateMeters()
                    let average = (0..<player.numberOfChannels).map { player.averagePower(forChannel: $0) }.max() ?? -160
                    let peak = (0..<player.numberOfChannels).map { player.peakPower(forChannel: $0) }.max() ?? -160
                    meters[i].update(power: average, peak: peak)
                } else { meters[i].update(power: -160, peak: -160) }
            } else {
                countdowns[i].stringValue = "− --:--"
                meters[i].update(power: -160, peak: -160)
            }
            states[i].stringValue = "\(Int(levels[i] * 100))% · " + (playing ? "играет" : "стоп")
            states[i].textColor = playing ? .systemGreen : .secondaryLabelColor
        }
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if let i = players.firstIndex(where: { $0 === player }) { finished.insert(i); midi?.lamp(i, false) }; refresh()
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if let i = players.firstIndex(where: { $0 === player }) { midi.lamp(i, false) }
        event.stringValue = error?.localizedDescription ?? "Ошибка декодирования"; refresh()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { stopAll(); for i in 0..<8 { midi?.lamp(i, false, loaded: true) } }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = App()
app.delegate = delegate
app.run()
