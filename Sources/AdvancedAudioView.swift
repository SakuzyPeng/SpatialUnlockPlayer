import SwiftUI

struct AdvancedAudioControl: View {
    @ObservedObject var model: AdvancedAudioModel
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: { Image(systemName: "slider.horizontal.3") }
            .help("空间音频高级设置").accessibilityLabel("空间音频高级设置")
            .accessibilityIdentifier("advancedAudioSettings")
            .popover(isPresented: $showing, arrowEdge: .bottom) { AdvancedAudioPanel(model: model) }
    }
}

private struct AdvancedAudioPanel: View {
    @ObservedObject var model: AdvancedAudioModel
    @State private var editingUID: String?
    @State private var draftDB: Double = 20
    @State private var dbText = "20.0"
    @State private var gesture = HeadroomEditGesture()
    @State private var inputError: String?
    @FocusState private var numberFocused: Bool

    private func loadDraft() {
        editingUID = model.deviceUID; draftDB = model.settings.headroomDB
        dbText = String(format: "%.1f", draftDB); inputError = nil
    }
    private func commitNumber() {
        guard let uid = editingUID, uid == model.deviceUID,
              let value = Double(dbText.trimmingCharacters(in: .whitespaces)), model.setHeadroomDB(value, uid: uid) else {
            inputError = "请输入 0–20 之间的数值。"; return
        }
        loadDraft()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("空间音频高级设置").font(.headline)
            Text(model.deviceName).font(.callout).textSelection(.enabled)
                .accessibilityIdentifier("advancedDeviceName")
            Group {
                Picker("处理余量", selection: Binding(get: { model.settings.headroomMode }, set: { value in
                    if let uid = editingUID { model.setHeadroomMode(value, uid: uid) }
                })) {
                    ForEach(AudioHeadroomMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("advancedHeadroomMode")
                if model.settings.headroomMode == .custom {
                    HStack(spacing: 10) {
                        Slider(value: Binding(get: { draftDB }, set: { if !gesture.isCancelled { draftDB = $0 } }),
                               in: 0...20, step: 0.1, onEditingChanged: { editing in
                            if editing { gesture.begin(uid: editingUID) }
                            else {
                                let commit = gesture.finish(currentUID: model.deviceUID)
                                if commit, let uid = editingUID { _ = model.setHeadroomDB(draftDB, uid: uid) }
                                loadDraft()
                            }
                        }).accessibilityLabel("处理余量").accessibilityIdentifier("advancedHeadroomSlider")
                        TextField("20.0", text: $dbText).frame(width: 65).textFieldStyle(.roundedBorder)
                            .focused($numberFocused).onSubmit(commitNumber)
                            .accessibilityLabel("处理余量数值").accessibilityIdentifier("advancedHeadroomDB")
                        Text("dB").foregroundStyle(.secondary)
                    }
                    if let inputError { Text(inputError).font(.caption).foregroundStyle(.orange) }
                    HStack {
                        Button("0 dB") { if let uid = editingUID { _ = model.setHeadroomDB(0, uid: uid); loadDraft() } }
                        Button("20 dB") { if let uid = editingUID { _ = model.setHeadroomDB(20, uid: uid); loadDraft() } }
                    }.controlSize(.small)
                }
                Text("通过动态处理前后配对的增益，调整压缩与限幅的触发程度。主音量独立控制。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                Picker("HRTF 模式", selection: Binding(get: { model.settings.hrtfMode }, set: { value in
                    if let uid = editingUID { model.setHRTFMode(value, uid: uid) }
                })) {
                    ForEach(AudioHRTFMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("advancedHRTFMode")
                Text("个性化模式请求使用已有档案，实际生效情况见下方状态。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.disabled(model.deviceUID == nil)
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Text(model.hrtfStatus).accessibilityIdentifier("advancedHRTFStatus")
                Text(model.headroomStatus).accessibilityIdentifier("advancedHeadroomStatus")
            }.font(.callout).accessibilityElement(children: .contain)
            Button("恢复此设备的系统设置") {
                if let uid = editingUID { model.reset(uid: uid); loadDraft() }
            }.disabled(model.deviceUID == nil).accessibilityIdentifier("advancedReset")
            Text("按输出设备记忆，仅影响本播放器。滑块松手或数值提交后生效，并恢复当前播放位置。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18).frame(width: 390).background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: loadDraft)
        .onChange(of: model.deviceUID) { _, _ in
            gesture.cancel()
            numberFocused = false; loadDraft()
        }
        .onChange(of: model.settings) { _, _ in if !gesture.isEditing && !numberFocused { loadDraft() } }
        .onChange(of: draftDB) { _, value in
            if gesture.isEditing { if !gesture.isCancelled { dbText = String(format: "%.1f", value) } }
            else if value != model.settings.headroomDB, let uid = editingUID, uid == model.deviceUID {
                _ = model.setHeadroomDB(value, uid: uid)
                dbText = String(format: "%.1f", model.settings.headroomDB)
            }
        }
    }
}
