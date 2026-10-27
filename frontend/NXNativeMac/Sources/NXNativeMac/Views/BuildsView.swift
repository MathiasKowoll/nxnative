import NXCore
import SwiftUI

struct BuildsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.builds.jobs.isEmpty {
                ContentUnavailableView("Sin construcciones", systemImage: "hammer",
                                       description: Text("Lanza una desde Carpetas NSP. Van de una en una: cada build usa todos los núcleos."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(model.builds.jobs) { BuildJobCard(job: $0) }
                    }
                    .padding(18)
                }
            }
        }
        .navigationTitle("Construcciones")
        .toolbar {
            Button("Limpiar terminadas") { model.builds.clearFinished() }
                .disabled(model.builds.jobs.allSatisfy(\.isActive))
        }
    }
}

struct BuildJobCard: View {
    let job: BuildJob
    @State private var showConsole = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    statusIcon
                    VStack(alignment: .leading) {
                        Text(job.title).font(.headline)
                        Text(statusText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if job.isActive {
                        Button("Cancelar", role: .destructive) { job.cancel() }
                    } else {
                        if let logs = job.logsDirectory { Button("Logs") { Finder.open(logs) } }
                        if let out = job.resultDirectory { Button("Mostrar salida") { Finder.open(out) } }
                    }
                }

                if job.status == .running, let f = job.overallFraction {
                    ProgressView(value: f)
                }

                ForEach(job.stages) { StageRow(stage: $0, total: job.stageCount) }

                if let err = job.lastError, !job.isActive {
                    Text(err).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }

                DisclosureGroup("Consola (\(job.messages.count))", isExpanded: $showConsole) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(job.messages) { m in
                                Text(m.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(m.isError ? Color.red : Color.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if !job.stderrTail.isEmpty {
                                Text(job.stderrTail)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.orange)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(6)
                    }
                    .frame(minHeight: 120, maxHeight: 280)
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.status {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        let elapsed = job.started.map { Duration.seconds((job.finished ?? Date()).timeIntervalSince($0)) }
        let t = elapsed.map { " · \($0.formatted(.time(pattern: .hourMinuteSecond)))" } ?? ""
        switch job.status {
        case .queued: return "En cola"
        case .running: return "En marcha" + t
        case .succeeded: return "Terminado" + t
        case let .failed(code): return "Falló (código \(code))" + t
        case .cancelled: return "Cancelado" + t
        }
    }
}

struct StageRow: View {
    let stage: StageState
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Group {
                    switch stage.ok {
                    case true?: Image(systemName: "checkmark").foregroundStyle(.green)
                    case false?: Image(systemName: "xmark").foregroundStyle(.red)
                    case nil: Image(systemName: "circle.dotted").foregroundStyle(.blue)
                    }
                }
                .frame(width: 14)
                Text("[\(stage.k)/\(total)] \(stage.name)").font(.callout.weight(.medium))
                if stage.ok == nil, !stage.step.isEmpty {
                    Text("· \(stage.step)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let e = stage.elapsed { Text(format(seconds: e)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
            }
            if stage.ok != nil, !stage.summary.isEmpty {
                Text(stage.summary).font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
            }
            if stage.ok == nil, let p = stage.progress {
                HStack {
                    if let f = p.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                    Text(counts(p)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.leading, 20)
            }
        }
    }

    private func counts(_ p: BuildProgress) -> String {
        var parts: [String] = []
        if let done = p.done {
            let est = p.estimated ? "~" : ""
            if p.unit == "B" {
                parts.append(Int64(done).bytes + (p.total.map { " / \(est)\(Int64($0).bytes)" } ?? ""))
            } else {
                let unit = p.unit.isEmpty ? "" : " \(p.unit)"
                parts.append("\(Int(done))" + (p.total.map { " / \(est)\(Int($0))" } ?? "") + unit)
            }
        }
        if let f = p.fraction { parts.append("\(Int(f * 100)) %") }
        if let eta = p.eta { parts.append("ETA \(format(seconds: eta))") }
        if !p.note.isEmpty { parts.append(p.note) }
        return parts.joined(separator: " · ")
    }

    private func format(seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}
