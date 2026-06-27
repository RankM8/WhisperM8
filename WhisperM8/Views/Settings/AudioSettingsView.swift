import SwiftUI

struct AudioSettingsView: View {
    @State private var deviceManager = AudioDeviceManager.shared
    @State private var selectedDeviceUID: String = ""

    var body: some View {
        Form {
            Section {
                Picker("Input Device", selection: $selectedDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(deviceManager.availableDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .onChange(of: selectedDeviceUID) { _, newValue in
                    deviceManager.selectedDeviceUID = newValue.isEmpty ? nil : newValue
                }

                Text("Select which microphone to use. Changes apply to the next recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            deviceManager.refreshDevices()
            selectedDeviceUID = deviceManager.selectedDeviceUID ?? ""
        }
    }
}
