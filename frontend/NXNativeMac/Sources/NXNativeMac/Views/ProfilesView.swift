import NXCore
import SwiftUI
import UniformTypeIdentifiers

/// El perfil activo, arriba de la barra lateral: quién juega ahora.
struct ProfileSwitcher: View {
    @Environment(AppModel.self) private var model
    @State private var managing = false

    var body: some View {
        Menu {
            ForEach(model.profileBook.profiles) { p in
                Button { model.selectProfile(p.id) } label: {
                    if p.id == model.activeProfile.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
            }
            Divider()
            Button("Gestionar perfiles…") { managing = true }
        } label: {
            Label(model.activeProfile.name, systemImage: "person.crop.circle")
        }
        .menuStyle(.borderlessButton)
        .help("Cada perfil tiene sus propias partidas y sus copias. Los ajustes de los juegos son comunes.")
        .disabled(anyRunning)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .sheet(isPresented: $managing) { ProfilesSheet() }
    }

    /// Cambiar de perfil con un juego abierto lo dejaría escribiendo en las
    /// partidas del perfil anterior.
    private var anyRunning: Bool { model.games.contains { model.runner.isRunning($0) } }
}

struct ProfilesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var editing: [String: String] = [:]
    @State private var pendingRemove: Profile?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Perfiles").font(.title2.bold())
            Text("Cada persona que juega en este Mac con sus propias partidas. «Principal» usa la carpeta de siempre, la misma que al abrir el juego desde Finder; los demás perfiles solo se aplican al jugar desde esta app.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(model.profileBook.profiles) { p in
                    HStack {
                        Image(systemName: p.id == model.activeProfile.id ? "person.crop.circle.fill" : "person.crop.circle")
                            .foregroundStyle(p.id == model.activeProfile.id ? Color.accentColor : .secondary)
                        if p.isMain {
                            Text(p.name)
                        } else {
                            TextField("Nombre", text: Binding(get: { editing[p.id] ?? p.name }, set: { editing[p.id] = $0 }))
                                .textFieldStyle(.plain)
                                .onSubmit { commitRename(p) }
                        }
                        Spacer()
                        if p.id != model.activeProfile.id {
                            Button("Usar") { model.selectProfile(p.id) }
                        } else {
                            Text("Activo").font(.caption).foregroundStyle(.secondary)
                        }
                        if !p.isMain {
                            Button(role: .destructive) { pendingRemove = p } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Quitar este perfil")
                        }
                    }
                }
            }
            .frame(minHeight: 180)

            HStack {
                TextField("Nombre del perfil nuevo", text: $newName).onSubmit(add)
                Button("Añadir", action: add)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Spacer()
                Button("Listo") {
                    for p in model.profileBook.profiles where editing[p.id] != nil { commitRename(p) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .confirmationDialog("¿Quitar el perfil \(pendingRemove?.name ?? "")?",
                            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } })) {
            Button("Quitar y llevar sus partidas a la Papelera", role: .destructive) { remove(discard: true) }
            Button("Quitar y dejar sus partidas en disco") { remove(discard: false) }
        } message: {
            Text("Sus partidas y sus copias pueden ir a la Papelera (se recuperan desde allí) o quedarse en disco: un perfil nuevo con el mismo nombre las vuelve a encontrar.")
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.addProfile(named: name)
        newName = ""
    }

    private func commitRename(_ p: Profile) {
        if let n = editing.removeValue(forKey: p.id) { model.renameProfile(p.id, to: n) }
    }

    private func remove(discard: Bool) {
        guard let p = pendingRemove else { return }
        editing[p.id] = nil
        model.removeProfile(p.id, discardSaves: discard)
        pendingRemove = nil
    }
}

/// Exportar o importar las partidas de todos los juegos del perfil activo.
struct AllSavesMenu: View {
    @Environment(AppModel.self) private var model
    @State private var pendingImport: URL?
    @State private var results: [SaveVault.ImportResult]?
    @State private var busy = false

    var body: some View {
        Menu {
            Button("Exportar todas las partidas…", action: exportAll)
            Button("Importar partidas…", action: chooseImport)
        } label: {
            Label("Partidas", systemImage: "externaldrive.badge.timemachine")
        }
        .help("Las partidas de todos los juegos del perfil «\(model.activeProfile.name)» en un solo zip, o al revés.")
        .disabled(busy || model.games.contains { model.runner.isRunning($0) })
        .confirmationDialog("¿Importar en el perfil «\(model.activeProfile.name)»?",
                            isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })) {
            Button("Importar", role: .destructive) {
                guard let url = pendingImport else { return }
                importAll(url)
            }
        } message: {
            Text("Cada juego del archivo reemplaza su partida en este perfil. Antes se copia la que hubiera («antes de restaurar») y la carpeta vieja va a la Papelera. Un juego que aún no está instalado recibe la partida igual, y la encontrará al instalarlo.")
        }
        .sheet(isPresented: Binding(get: { results != nil }, set: { if !$0 { results = nil } })) {
            ImportResultsSheet(results: results ?? [])
        }
    }

    private func exportAll() {
        let p = NSSavePanel()
        let d = Date().formatted(.iso8601.year().month().day())
        p.nameFieldStringValue = "Partidas nxnative - \(model.activeProfile.name) \(d).zip".replacingOccurrences(of: "/", with: "-")
        p.allowedContentTypes = [.zip]
        guard p.runModal() == .OK, let out = p.url else { return }
        Task {
            busy = true
            defer { busy = false }
            do {
                let n = try await model.exportAllSaves(to: out)
                model.notice = "\(n) partidas de «\(model.activeProfile.name)» exportadas a \(out.path)"
            } catch {
                model.notice = "No se pudieron exportar: \(error.localizedDescription)"
            }
        }
    }

    private func chooseImport() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.zip]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return }
        pendingImport = url
    }

    private func importAll(_ url: URL) {
        Task {
            busy = true
            defer { busy = false }
            do { results = try await model.importAllSaves(from: url) } catch {
                model.notice = "No se pudo importar: \(error.localizedDescription)"
            }
        }
    }
}

struct ImportResultsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let results: [SaveVault.ImportResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let ok = results.filter { $0.error == nil }.count
            Text("Importadas \(ok) de \(results.count)").font(.title2.bold())
            List(results, id: \.titleID) { r in
                HStack(alignment: .top) {
                    Image(systemName: r.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(r.error == nil ? .green : .orange)
                    VStack(alignment: .leading) {
                        Text(r.game.isEmpty ? r.titleID : r.game)
                        Text(r.error ?? r.titleID).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 200)
            HStack { Spacer(); Button("Listo") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 460)
    }
}
