import SwiftUI

struct WorkshopControl: View {
    let title: String
    let value: String
    let symbol: String
    let selected: Bool
    let adjustable: Bool
    let enabled: Bool
    let activate: () -> Void
    let adjust: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: activate) {
                HStack(spacing: 14) {
                    Image(systemName: symbol).font(.title3).frame(width: 28)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.headline)
                        Text(value).font(.callout).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: adjustable ? "arrow.left.arrow.right" : "chevron.right").foregroundStyle(.secondary)
                }
                .padding(15).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Color.accentColor.opacity(0.16) : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
                .overlay { RoundedRectangle(cornerRadius: 13).stroke(selected ? Color.accentColor : .clear, lineWidth: 2) }
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if adjustable {
                Button { adjust(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel(title + ": anterior")
                Button { adjust(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel(title + ": siguiente")
            }
        }
        .disabled(!enabled).opacity(enabled ? 1 : 0.55)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension BuildJob {
    var workshopStatus: String {
        switch status {
        case .queued: "En cola"
        case .running: cancellationRequested ? "Deteniendo…" : "En curso"
        case .succeeded: "Terminado"
        case .failed: "Falló · disponible para reintentar"
        case .cancelled: "Cancelado"
        case .interrupted: "Sesión interrumpida · revisar antes de reintentar"
        }
    }
}
