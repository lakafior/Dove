import DoveKit
import SwiftUI

/// Everything about one debrid service: its key (saved to the Keychain and tested), TorBox's plan, and whether
/// NZBs may go there.
struct DebridServiceView: View {
    @Environment(AppModel.self) private var model
    let backend: BackendID
    @State private var value = ""
    @State private var status: SettingsStatus?
    @State private var usenet = false

    private var key: CredentialKey {
        switch backend {
        case .realDebrid: .realDebridAPIKey
        case .torBox: .torBoxAPIKey
        case .offcloud: .offcloudAPIKey
        case .debridLink: .debridLinkAPIKey
        case .premiumize: .premiumizeAPIKey
        case .allDebrid: .allDebridAPIKey
        case .nzbdav: .nzbdavAPIKey
        // Never shown for places or nzbdav: those have their own screens.
        case .iCloudDrive, .calibre: preconditionFailure("\(backend.displayName) has no key")
        }
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                SecureField("API key", text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(saveAndTest)
            } header: {
                Text("API key")
            } footer: {
                Text(backend.keyHelp)
            }
            Section {
                Button(action: saveAndTest) {
                    HStack {
                        Text("Save and test connection")
                        if status == .testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(status == .testing)
                if let status, status != .testing { SettingsStatusView(status: status) }
            }
            if model.isConfigured(backend) {
                if backend == .torBox {
                    Section {
                        Picker("Plan", selection: $model.torBoxPlan.chosen) {
                            Text(model.torBoxPlan.detected.map { "Automatic (\($0.name))" } ?? "Automatic").tag(TorBoxPlan?.none)
                            ForEach(TorBoxPlan.ordered) { Text($0.name).tag(Optional($0)) }
                        }
                    } header: {
                        Text("Plan")
                    } footer: {
                        Text(torBoxPlanFooter)
                    }
                }
                if backend.offersUsenet {
                    Section {
                        Toggle("Send NZBs here", isOn: $usenet)
                            .disabled(planWithoutUsenet)
                    } header: {
                        Text("Usenet")
                    } footer: {
                        Text(usenetFooter)
                    }
                }
                Section {
                    Button("Remove key", role: .destructive) {
                        value = ""
                        saveAndTest()
                    }
                }
            }
        }
        .navigationTitle(backend.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { value = (try? model.keychain.get(key)) ?? "" }
        // The plan and the key decide it too, so read it again whenever they change.
        .task(id: model.torBoxPlan.plan) { usenet = model.usenetEnabled(backend) }
        .onChange(of: usenet) {
            guard usenet != model.usenetEnabled(backend) else { return }
            model.setUsenet(backend, enabled: usenet)
        }
    }

    /// TorBox on a known plan other than Pro.
    private var planWithoutUsenet: Bool {
        backend == .torBox && model.torBoxPlan.plan.map { !$0.includesUsenet } == true
    }

    private var usenetFooter: String {
        let order = "NZBs follow Order and fallback › NZBs."
        switch backend {
        case .torBox: return planWithoutUsenet ? "Your TorBox plan has no Usenet: it needs Pro." : "Needs the Pro plan. \(order)"
        case .premiumize: return "Every Premiumize plan includes Usenet. \(order)"
        default: return order
        }
    }

    private var torBoxPlanFooter: String {
        let source = model.torBoxPlan.detected == nil
            ? "TorBox has not reported the plan yet; pick it here."
            : "Read from your TorBox account; pick one only if it is wrong."
        guard let plan = model.torBoxPlan.plan else { return source }
        return "\(source) \(plan.name): \(plan.features)."
    }

    private func saveAndTest() {
        do {
            try model.keychain.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: key)
        } catch {
            status = .failure("Keychain error: \(error)")
            return
        }
        model.reloadBackends()
        usenet = model.usenetEnabled(backend)
        guard let service = model.backend(backend) else {
            status = .note("Key removed.")
            return
        }
        status = .testing
        Task {
            do {
                try await service.validateCredentials()
                status = .success("Connected to \(backend.displayName).")
                await model.refreshAccounts(force: true)
            } catch {
                status = SettingsStatus(error)
            }
        }
    }
}
