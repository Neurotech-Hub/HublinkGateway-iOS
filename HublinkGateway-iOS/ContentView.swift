//
//  ContentView.swift
//  HublinkGateway-iOS
//
//  Created by Matt Gaidica on 8/11/25.
//

import SwiftUI
import CoreBluetooth

// MARK: - BLE UUIDs
struct HublinkUUIDs {
    static let service = CBUUID(string: "57617368-5501-0001-8000-00805f9b34fb")
    static let filename = CBUUID(string: "57617368-5502-0001-8000-00805f9b34fb")
    static let fileTransfer = CBUUID(string: "57617368-5503-0001-8000-00805f9b34fb")
    static let gateway = CBUUID(string: "57617368-5504-0001-8000-00805f9b34fb")
    static let node = CBUUID(string: "57617368-5505-0001-8000-00805f9b34fb")
}

// MARK: - App State
class AppState: ObservableObject {
    // Removed deviceNameFilter since we're filtering by service
    @Published var isScanning = false
    @Published var isConnected = false
    @Published var discoveredDevices: [CBPeripheral] = []
    @Published var connectedDevice: CBPeripheral?
    @Published var terminalLog: [String] = []
    @Published var connectionStatus = "Ready"
    @Published var requestFileName = ""
    @Published var receivedFileContent = ""
    @Published var showClearMemoryAlert = false
    @Published var clearMemoryStep = 1
    
    private var clearDevicesTimer: Timer?
    
    func log(_ message: String) {
        let timestamp = DateFormatter.logFormatter.string(from: Date())
        terminalLog.append("[\(timestamp)] \(message)")
        if terminalLog.count > 1000 {
            terminalLog.removeFirst(100)
        }
    }
    
    func clearLog() {
        terminalLog.removeAll()
    }
    
    func scheduleClearDevices() {
        // Cancel existing timer
        clearDevicesTimer?.invalidate()
        
        // Schedule new timer to clear devices after 30 seconds
        clearDevicesTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.discoveredDevices.removeAll()
            }
        }
        RunLoop.main.add(clearDevicesTimer!, forMode: .common)
    }
    
    func cancelClearDevices() {
        clearDevicesTimer?.invalidate()
        clearDevicesTimer = nil
    }
}

// MARK: - BLE Manager
class BLEManager: NSObject, ObservableObject {
    private var centralManager: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    private var filenameCharacteristic: CBCharacteristic?
    private var fileTransferCharacteristic: CBCharacteristic?
    private var gatewayCharacteristic: CBCharacteristic?
    private var nodeCharacteristic: CBCharacteristic?
    
    @Published var appState: AppState
    
    init(appState: AppState) {
        self.appState = appState
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    func startScanning() {
        guard let centralManager = centralManager,
              centralManager.state == .poweredOn else {
            appState.log("ERROR: Bluetooth not available - State: \(centralManager?.state.rawValue ?? -1)")
            return
        }
        
        appState.isScanning = true
        appState.discoveredDevices.removeAll()
        appState.cancelClearDevices() // Cancel any pending clear timer
        appState.log("Starting BLE scan for service: \(HublinkUUIDs.service.uuidString)")
        
        centralManager.scanForPeripherals(
            withServices: [HublinkUUIDs.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        
        // Stop scanning after 10 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            self.stopScanning()
        }
    }
    
    func stopScanning() {
        centralManager?.stopScan()
        appState.isScanning = false
        appState.log("Scan stopped")
        appState.scheduleClearDevices()
    }
    
    func connect(to peripheral: CBPeripheral) {
        appState.log("Connecting to \(peripheral.name ?? "Unknown")...")
        centralManager?.connect(peripheral, options: nil)
    }
    
    func disconnect() {
        if let peripheral = connectedPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
    }
    
    func sendTimestamp() {
        guard let characteristic = gatewayCharacteristic else {
            appState.log("ERROR: Gateway characteristic not available")
            return
        }
        
        let timestamp = Int(Date().timeIntervalSince1970)
        let payload = "{\"timestamp\": \(timestamp)}"
        
        if let data = payload.data(using: .utf8) {
            connectedPeripheral?.writeValue(data, for: characteristic, type: .withResponse)
            appState.log("SENT: \(payload)")
        }
    }
    
    func sendFilenamesRequest() {
        guard let characteristic = gatewayCharacteristic else {
            appState.log("ERROR: Gateway characteristic not available")
            return
        }
        
        let payload = "{\"sendFilenames\": true}"
        
        if let data = payload.data(using: .utf8) {
            connectedPeripheral?.writeValue(data, for: characteristic, type: .withResponse)
            appState.log("SENT: \(payload)")
        }
    }
    
    func clearMemory() {
        guard let characteristic = gatewayCharacteristic else {
            appState.log("ERROR: Gateway characteristic not available")
            return
        }
        
        let payload = "{\"clearMemory\": true}"
        
        if let data = payload.data(using: .utf8) {
            connectedPeripheral?.writeValue(data, for: characteristic, type: .withResponse)
            appState.log("SENT: \(payload)")
        }
    }
    
    func setOperatingMode(_ mode: Int) {
        guard let characteristic = gatewayCharacteristic else {
            appState.log("ERROR: Gateway characteristic not available")
            return
        }
        
        let payload = "{\"operatingMode\":\(mode)}"
        
        if let data = payload.data(using: .utf8) {
            connectedPeripheral?.writeValue(data, for: characteristic, type: .withResponse)
            appState.log("SENT: \(payload)")
        }
    }
    
    func requestFilenames() {
        guard let characteristic = filenameCharacteristic else {
            appState.log("ERROR: Filename characteristic not available")
            return
        }
        
        let payload = "request"
        if let data = payload.data(using: .utf8) {
            connectedPeripheral?.writeValue(data, for: characteristic, type: .withResponse)
            appState.log("SENT: Request filenames")
        }
    }
    
    func startFileTransfer(filename: String) {
        guard let characteristic = filenameCharacteristic else {
            appState.log("ERROR: Filename characteristic not available")
            return
        }
        
        // Clear previous file content when starting new transfer
        appState.receivedFileContent = ""
        
        if let data = filename.data(using: .utf8) {
            connectedPeripheral?.writeValue(data, for: characteristic, type: .withResponse)
            appState.log("SENT: Request file transfer for '\(filename)'")
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            appState.log("Bluetooth ready")
        case .poweredOff:
            appState.log("ERROR: Bluetooth powered off")
        case .unauthorized:
            appState.log("ERROR: Bluetooth unauthorized")
        case .unsupported:
            appState.log("ERROR: Bluetooth unsupported")
        default:
            appState.log("ERROR: Bluetooth state: \(central.state.rawValue)")
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if let name = peripheral.name {
            if !appState.discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
                appState.discoveredDevices.append(peripheral)
                appState.log("DISCOVERED: \(name) (RSSI: \(RSSI))")
            }
        } else {
            if !appState.discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
                appState.discoveredDevices.append(peripheral)
                appState.log("DISCOVERED: Unnamed device \(peripheral.identifier.uuidString) (RSSI: \(RSSI))")
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // Stop scanning when we connect
        stopScanning()
        
        appState.isConnected = true
        appState.connectedDevice = peripheral
        appState.connectionStatus = "Connected to \(peripheral.name ?? "Unknown")"
        appState.log("CONNECTED: \(peripheral.name ?? "Unknown")")
        
        // Clear file content on new connection
        appState.receivedFileContent = ""
        
        connectedPeripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([HublinkUUIDs.service])
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        appState.log("ERROR: Failed to connect - \(error?.localizedDescription ?? "Unknown error")")
        appState.connectionStatus = "Connection failed"
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        appState.isConnected = false
        appState.connectedDevice = nil
        appState.connectionStatus = "Disconnected"
        
        if let error = error {
            appState.log("DISCONNECTED: \(peripheral.name ?? "Unknown") - Error: \(error.localizedDescription)")
        } else {
            appState.log("DISCONNECTED: \(peripheral.name ?? "Unknown") - Device disconnected")
        }
        
        // Clear connected state
        connectedPeripheral = nil
        filenameCharacteristic = nil
        fileTransferCharacteristic = nil
        gatewayCharacteristic = nil
        nodeCharacteristic = nil
        
        // Clear any pending timers
        appState.cancelClearDevices()
        
        // Clear the request filename field and file content
        appState.requestFileName = ""
        appState.receivedFileContent = ""
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            appState.log("ERROR: Service discovery failed - \(error!.localizedDescription)")
            return
        }
        
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            appState.log("ERROR: Characteristic discovery failed - \(error!.localizedDescription)")
            return
        }
        
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case HublinkUUIDs.filename:
                filenameCharacteristic = characteristic
                appState.log("Found filename characteristic")
            case HublinkUUIDs.fileTransfer:
                fileTransferCharacteristic = characteristic
                appState.log("Found file transfer characteristic")
            case HublinkUUIDs.gateway:
                gatewayCharacteristic = characteristic
                appState.log("Found gateway characteristic")
            case HublinkUUIDs.node:
                nodeCharacteristic = characteristic
                appState.log("Found node characteristic")
            default:
                break
            }
        }
        
        // Enable notifications for relevant characteristics
        if let filenameChar = filenameCharacteristic {
            peripheral.setNotifyValue(true, for: filenameChar)
        }
        if let fileTransferChar = fileTransferCharacteristic {
            peripheral.setNotifyValue(true, for: fileTransferChar)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            appState.log("ERROR: Characteristic update failed - \(error!.localizedDescription)")
            return
        }
        
        if let data = characteristic.value,
           let string = String(data: data, encoding: .utf8) {
            appState.log("RECEIVED: \(string)")
            
            // Check if this is a filename response and auto-fill the first filename
            if string.contains("|") && string.contains(";") && string.contains("EOF") {
                let components = string.components(separatedBy: ";")
                for component in components {
                    if component.contains("|") && !component.contains("EOF") {
                        let filename = component.components(separatedBy: "|").first ?? ""
                        if !filename.isEmpty {
                            DispatchQueue.main.async {
                                self.appState.requestFileName = filename
                            }
                            break
                        }
                    }
                }
            }
        } else if let data = characteristic.value {
            // Handle binary file data
            if characteristic.uuid == HublinkUUIDs.fileTransfer {
                DispatchQueue.main.async {
                    // Convert bytes to hex string for display
                    let hexString = data.map { String(format: "%02X", $0) }.joined()
                    self.appState.receivedFileContent += hexString
                }
            }
        }
    }
}

// MARK: - Date Formatter Extension
extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var appState = AppState()
    @StateObject private var bleManager: BLEManager
    
    init() {
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        _bleManager = StateObject(wrappedValue: BLEManager(appState: state))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            // Main Content
            if appState.isConnected {
                connectedView
            } else {
                deviceListView
            }
            
            Spacer()
            
            // Terminal - pinned to bottom
            terminalView
        }
        .background(Color(.systemBackground))
    }
    
    // MARK: - Header View
    private var headerView: some View {
        VStack(spacing: 16) {
            HStack(spacing: 0) {
                Text("Hublink")
                    .font(.system(size: 24, weight: .heavy, design: .default))
                    .foregroundColor(.primary)
                Text("Gateway")
                    .font(.system(size: 24, weight: .regular, design: .default))
                    .foregroundColor(.primary)
            }
            
            Button(action: {
                if appState.isScanning {
                    bleManager.stopScanning()
                } else {
                    bleManager.startScanning()
                }
            }) {
                Text(appState.isScanning ? "Stop" : "Scan")
                    .font(.system(size: 20, weight: .semibold, design: .default))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 0.42, green: 0.05, blue: 0.68), // Deep purple ~#6A0DAD
                                Color(red: 1.0, green: 0.0, blue: 1.0)     // Vibrant fuchsia ~#FF00FF
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .blue.opacity(0.3), radius: 8, x: 0, y: 4)
            }
            .disabled(appState.isConnected)
            .opacity(appState.isConnected ? 0.6 : 1.0)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
    }
    
    // MARK: - Device List View
    private var deviceListView: some View {
        List {
            ForEach(appState.discoveredDevices, id: \.identifier) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name ?? "Unknown")
                            .font(.custom("Outfit", size: 16))
                            .fontWeight(.medium)
                        
                        Text(device.identifier.uuidString)
                            .font(.custom("Outfit", size: 12))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        bleManager.connect(to: device)
                    }) {
                        Text("Connect")
                            .font(.system(size: 14, weight: .medium, design: .default))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(height: 36)
                    }
                    .buttonStyle(.bordered)
                    .disabled(appState.isConnected)
                }
                .padding(.vertical, 8)
            }
        }
        .listStyle(PlainListStyle())
    }
    
    // MARK: - Connected View
    private var connectedView: some View {
        VStack(spacing: 20) {
            // Header with disconnect
            HStack {
                Text("Connected to \(appState.connectedDevice?.name ?? "Device")")
                    .font(.system(size: 16, weight: .medium, design: .default))
                    .foregroundColor(.green)
                Spacer()
                Button(action: {
                    bleManager.disconnect()
                }) {
                    Text("Disconnect")
                        .font(.system(size: 14, weight: .medium, design: .default))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(height: 36)
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }
            
            // JSON commands - single row
            HStack(spacing: 12) {
                Button(action: {
                    bleManager.sendTimestamp()
                }) {
                    Text("Timestamp")
                        .font(.system(size: 14, weight: .medium, design: .default))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(.bordered)
                
                Button(action: {
                    bleManager.sendFilenamesRequest()
                }) {
                    Text("Get Files")
                        .font(.system(size: 14, weight: .medium, design: .default))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(.bordered)
                
                Button(action: {
                    appState.clearMemoryStep = 1
                    appState.showClearMemoryAlert = true
                }) {
                    Text("Clear Memory")
                        .font(.system(size: 14, weight: .medium, design: .default))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(.bordered)
            }
            
            // Operating mode buttons
            HStack(spacing: 12) {
                Button(action: {
                    bleManager.setOperatingMode(0)
                }) {
                    Text("Mode 0")
                        .font(.system(size: 14, weight: .medium, design: .default))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(.bordered)
                
                Button(action: {
                    bleManager.setOperatingMode(1)
                }) {
                    Text("Mode 1")
                        .font(.system(size: 14, weight: .medium, design: .default))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(.bordered)
            }
            
            // File request input
            HStack(spacing: 12) {
                TextField("Enter filename", text: $appState.requestFileName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.system(size: 14, design: .monospaced))
                
                Button(action: {
                    if !appState.requestFileName.isEmpty {
                        bleManager.startFileTransfer(filename: appState.requestFileName)
                    }
                }) {
                    Text("Request")
                        .font(.system(size: 14, weight: .medium, design: .default))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(.bordered)
                .disabled(appState.requestFileName.isEmpty)
            }
            
            // File content display area
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("File Content:")
                        .font(.system(size: 14, weight: .medium, design: .default))
                    Spacer()
                    Button("Copy") {
                        UIPasteboard.general.string = appState.receivedFileContent
                        appState.log("✓ Copied file content to clipboard (\(appState.receivedFileContent.count) characters)")
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .disabled(appState.receivedFileContent.isEmpty)
                    
                    Button("Clear") {
                        appState.receivedFileContent = ""
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .disabled(appState.receivedFileContent.isEmpty)
                }
                
                ScrollView {
                    Text(appState.receivedFileContent.isEmpty ? "No file content received" : appState.receivedFileContent)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: .infinity)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            
            // Removed utility buttons - not needed
        }
        .padding()
        .background(Color(.systemBackground))
        .alert("Clear Memory", isPresented: $appState.showClearMemoryAlert) {
            Button("Cancel", role: .cancel) {
                appState.clearMemoryStep = 1
            }
            Button(appState.clearMemoryStep == 1 ? "Continue" : "Clear Memory", role: .destructive) {
                if appState.clearMemoryStep == 1 {
                    appState.clearMemoryStep = 2
                    // Show the same alert again with different content
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        appState.showClearMemoryAlert = true
                    }
                } else {
                    bleManager.clearMemory()
                    appState.clearMemoryStep = 1
                }
            }
        } message: {
            if appState.clearMemoryStep == 1 {
                Text("This will clear all memory on the device. Are you sure you want to continue?")
            } else {
                Text("This will permanently clear all memory on the device. This action cannot be undone. Are you absolutely sure?")
            }
        }
    }
    
    // MARK: - Terminal View
    private var terminalView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(appState.terminalLog.enumerated()), id: \.offset) { index, log in
                        Text(log)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: appState.terminalLog.count) { oldValue, newValue in
                if let lastIndex = appState.terminalLog.indices.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(.systemGray6))
        .frame(maxHeight: 150)
    }
}

#Preview {
    ContentView()
}
