// Pairing sheet: find a PC, show the PIN to type into Sunshine, confirm.

import AppKit
import SwiftUI

struct MVPairingSheet: View {
    @ObservedObject var model: MVModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Which step shows: each new one slides in from the side.
    private var stepKey: Int {
        switch model.pairingStep {
        case .search: return 0
        case .waiting: return 1
        case .paired: return 2
        case .failed: return 3
        }
    }

    private var stepTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity)
    }

    var body: some View {
        Group {
            switch model.pairingStep {
            case .search:
                MVPairingSearch(model: model)
                    .transition(stepTransition)
            case .waiting(let computerId, let pin):
                MVPairingPin(model: model, computer: computer(computerId), pin: pin)
                    .transition(stepTransition)
            case .paired(let computerId):
                MVPairingDone(model: model, computer: computer(computerId))
                    .transition(stepTransition)
            case .failed(let computerId, let error):
                MVPairingFailed(model: model, computer: computer(computerId), error: error)
                    .transition(stepTransition)
            }
        }
        .padding(24)
        .frame(width: 460)
        .animation(.mvState, value: stepKey)
    }

    private func computer(_ id: String) -> MVComputer? {
        model.computers.first { $0.id == id }
    }
}

struct MVSheetHeader: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 20, weight: .bold))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Step 1: search

struct MVPairingSearch: View {
    @ObservedObject var model: MVModel
    @State private var address = ""

    private var candidates: [MVComputer] {
        model.computers.filter { $0.online && !$0.paired }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MVSheetHeader(title: "Ajouter un ordinateur")

            VStack(alignment: .leading, spacing: 0) {
                Text("Sur ton réseau")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)

                VStack(spacing: 0) {
                    ForEach(candidates) { computer in
                        HStack(spacing: 10) {
                            Image(systemName: "desktopcomputer").font(.system(size: 16))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(computer.name).font(.system(size: 13, weight: .semibold))
                                Text("Prêt à appairer").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Appairer") { model.pair(computer) }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        Divider().padding(.leading, 12)
                    }
                    HStack(spacing: 10) {
                        // The same waves as a PC waking up: Moonvibe listens on the network
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(mvAccentForeground)
                            .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
                            .accessibilityHidden(true)
                        Text("Recherche en cours…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor)))
                .animation(.mvState, value: candidates.map(\.id))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Ou ajoute-le à la main")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Adresse IP ou nom, ex. 192.168.1.53", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.addHost(address) }
                    Button {
                        model.addHost(address)
                    } label: {
                        if model.addingHost {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Ajouter")
                        }
                    }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || model.addingHost)
                }
                if let error = model.addHostError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(mvDanger)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .animation(.mvState, value: model.addHostError)

            HStack {
                Spacer()
                Button("Annuler") { model.showPairing = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}

// MARK: - Step 2: PIN

struct MVPairingPin: View {
    @ObservedObject var model: MVModel
    let computer: MVComputer?
    let pin: String
    @State private var copied = false
    /// The digits drop into their boxes one after the other.
    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var name: String { computer?.name ?? String(localized: "ton PC") }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MVSheetHeader(title: "Appairer \(name)")

            HStack(spacing: 10) {
                ForEach(Array(paddedPin.enumerated()), id: \.offset) { index, digit in
                    Text(String(digit))
                        .font(.system(size: 42, weight: .bold).monospacedDigit())
                        .contentTransition(.numericText())
                        .opacity(revealed ? 1 : 0)
                        .offset(y: revealed || reduceMotion ? 0 : -14)
                        .animation(.snappy(duration: 0.35, extraBounce: 0.2).delay(Double(index) * 0.07), value: revealed)
                        .frame(maxWidth: .infinity)
                        .frame(height: 72)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor)))
                }
            }
            .animation(.mvState, value: pin)
            .onAppear { revealed = true }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Code \(pin.map(String.init).joined(separator: " "))")

            VStack(alignment: .leading, spacing: 8) {
                MVPairingInstruction(number: 1, text: "Sur \(name), ouvre Sunshine : **localhost:47990**, onglet **PIN**.")
                MVPairingInstruction(number: 2, text: "Saisis le code et un nom pour ce Mac.")
            }

            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("En attente \(mvOf(name))…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pin, forType: .string)
                    withAnimation(.mvState) { copied = true }
                } label: {
                    Label {
                        if copied {
                            Text("Copié")
                        } else {
                            Text("Copier le code")
                        }
                    } icon: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(pin.isEmpty)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))

            HStack {
                Link("Sunshine n'est pas installé ?", destination: URL(string: "https://github.com/LizardByte/Sunshine")!)
                    .font(.system(size: 12))
                Spacer()
                Button("Annuler") { model.pairingStep = .search }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var paddedPin: [Character] {
        let digits = Array(pin)
        return digits.isEmpty ? Array(repeating: "·", count: 4) : digits
    }
}

struct MVPairingInstruction: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(mvAccentForeground)
                .frame(width: 18, height: 18)
                .background(Circle().fill(mvAccent.opacity(0.14)))
                .accessibilityHidden(true)
            Text(text).font(.system(size: 13))
        }
    }
}

// MARK: - Step 3: paired

/// The start of a story with this PC: the check draws itself, stars burst out behind it,
/// then the name and the button rise in.
struct MVPairingDone: View {
    @ObservedObject var model: MVModel
    let computer: MVComputer?
    @State private var celebrated = false
    @State private var bursts = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 14) {
            MVDrawnCheckmark(drawn: celebrated)
                .overlay {
                    MVLaunchBurst(trigger: bursts, color: mvOnline)
                        .frame(width: 420, height: 320)
                }
            Group {
                Text("\(computer?.name ?? String(localized: "Ton PC")) est prêt")
                    .font(.system(size: 20, weight: .bold))
                MVPrimaryButton(title: "C'est parti", busy: false, disabled: false) {
                    model.finishPairing()
                }
                .padding(.top, 6)
            }
            .opacity(celebrated ? 1 : 0)
            .offset(y: celebrated || reduceMotion ? 0 : 10)
            .animation(.smooth(duration: 0.45).delay(0.25), value: celebrated)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            celebrated = true
            bursts += 1
        }
    }
}

/// A large green check that draws itself in (macOS 26), or pops in before.
struct MVDrawnCheckmark: View {
    let drawn: Bool

    var body: some View {
        let check = Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 52))
            .foregroundStyle(mvOnline)
            .accessibilityHidden(true)
        if #available(macOS 26.0, *) {
            check.symbolEffect(.drawOn, isActive: !drawn)
        } else {
            check.symbolEffect(.bounce, value: drawn)
        }
    }
}

// MARK: - Errors

/// The failure's warning sign, which shakes its head once (macOS 15 and later).
private struct MVShakingWarning: View {
    @State private var shakes = 0

    var body: some View {
        let sign = Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 22))
            .foregroundStyle(mvDanger)
            .accessibilityHidden(true)
        Group {
            if #available(macOS 15.0, *) {
                sign.symbolEffect(.wiggle, value: shakes)
            } else {
                sign.symbolEffect(.bounce, value: shakes)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(250))
            shakes += 1
        }
    }
}

struct MVPairingFailed: View {
    @ObservedObject var model: MVModel
    let computer: MVComputer?
    let error: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                MVShakingWarning()
                Text("L'appairage n'a pas abouti")
                    .font(.system(size: 20, weight: .bold))
            }
            Text(error)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Annuler") { model.pairingStep = .search }
                    .keyboardShortcut(.cancelAction)
                if let computer {
                    Button("Réessayer") { model.pair(computer) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}
