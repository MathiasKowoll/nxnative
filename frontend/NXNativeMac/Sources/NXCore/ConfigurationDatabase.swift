import Foundation
import SQLite3

/// Persistencia de configuraciones de NXNative.
///
/// SQLite es la fuente de trabajo de la app, pero cada perfil también se
/// materializa en `env.txt`. Así un juego abierto desde Finder sigue viendo
/// exactamente las mismas variables y una edición externa no queda escondida:
/// si el archivo cambió desde la última sincronización, se importa de nuevo.
public final class ConfigurationDatabase {
    public enum SyncAction: String, Sendable, Equatable {
        case created
        case unchanged
        case importedFromFile
        case restoredToFile
        case saved
    }

    public struct SyncResult: Sendable, Equatable {
        public let env: EnvFile
        public let action: SyncAction

        public init(env: EnvFile, action: SyncAction) {
            self.env = env
            self.action = action
        }
    }

    public enum DatabaseError: Error, LocalizedError, Equatable {
        case open(String)
        case sql(String)
        case bind(String)
        case step(String)

        public var errorDescription: String? {
            switch self {
            case .open(let message): return "No se pudo abrir la base de configuraciones: " + message
            case .sql(let message): return "Error SQLite: " + message
            case .bind(let message): return "No se pudo guardar una configuración: " + message
            case .step(let message): return "No se pudo leer una configuración: " + message
            }
        }
    }

    public static let schemaVersion = 1

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NXNativeMac/configuration.sqlite", isDirectory: false)
    }

    public let url: URL

    public init(url: URL = ConfigurationDatabase.defaultURL) {
        self.url = url
    }

    /// Carga la configuración, importándola desde el archivo antiguo si aún no
    /// existe en SQLite. Si el archivo se editó fuera de la app, ese contenido
    /// gana para no borrar una decisión hecha desde Finder o un editor.
    public func loadOrImport(titleID: String, envURL: URL) throws -> EnvFile {
        try synchronize(titleID: titleID, envURL: envURL).env
    }

    /// Reconcilia las dos representaciones de un perfil y deja ambas en el
    /// mismo estado. `env.txt` tiene prioridad cuando existe y su texto difiere
    /// de SQLite, porque es la copia que consume el juego fuera de la app.
    public func synchronize(titleID: String, envURL: URL) throws -> SyncResult {
        let fileExists = FileManager.default.fileExists(atPath: envURL.path)
        let fileText = fileExists ? try String(contentsOf: envURL, encoding: .utf8) : nil

        return try withDatabase { db in
            try ensureSchema(db)
            guard let stored = try document(db, titleID: titleID) else {
                let raw = fileText ?? ""
                try store(db, titleID: titleID, rawText: raw, env: EnvFile(text: raw))
                return SyncResult(env: EnvFile(text: raw), action: fileExists ? .importedFromFile : .created)
            }

            if let fileText, fileText != stored {
                let env = EnvFile(text: fileText)
                try store(db, titleID: titleID, rawText: fileText, env: env)
                return SyncResult(env: env, action: .importedFromFile)
            }

            let env = EnvFile(text: stored)
            if !fileExists, !stored.isEmpty {
                try writeRaw(stored, to: envURL)
                return SyncResult(env: env, action: .restoredToFile)
            }
            return SyncResult(env: env, action: .unchanged)
        }
    }

    /// Escribe primero la copia compatible con el lanzador y luego actualiza
    /// SQLite. Si la base falla, el juego conserva un `env.txt` válido y la
    /// siguiente carga volverá a importarlo.
    @discardableResult
    public func save(titleID: String, env: EnvFile, envURL: URL) throws -> SyncAction {
        let raw = env.text
        if raw.isEmpty {
            if FileManager.default.fileExists(atPath: envURL.path) {
                try FileManager.default.removeItem(at: envURL)
            }
        } else {
            try writeRaw(raw, to: envURL)
        }

        try withDatabase { db in
            try ensureSchema(db)
            try store(db, titleID: titleID, rawText: raw, env: env)
        }
        return .saved
    }

    // MARK: SQLite internals

    public func loadBuildHistory() throws -> [WorkshopBuild] {
        try withDatabase { db in
            try execute(db, "CREATE TABLE IF NOT EXISTS workshop_history (id INTEGER PRIMARY KEY CHECK(id=1), payload TEXT NOT NULL)")
            let statement = try prepare(db, "SELECT payload FROM workshop_history WHERE id=1")
            defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return [] }
            guard result == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
                throw DatabaseError.step(errorMessage(db))
            }
            return try JSONDecoder().decode([WorkshopBuild].self, from: Data(String(cString: value).utf8))
        }
    }

    public func saveBuildHistory(_ records: [WorkshopBuild]) throws {
        let data = try JSONEncoder().encode(records)
        try withDatabase { db in
            try execute(db, "CREATE TABLE IF NOT EXISTS workshop_history (id INTEGER PRIMARY KEY CHECK(id=1), payload TEXT NOT NULL)")
            let statement = try prepare(db, "INSERT INTO workshop_history(id,payload) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload")
            defer { sqlite3_finalize(statement) }
            try bind(String(decoding: data, as: UTF8.self), at: 1, to: statement)
            try step(statement, db: db)
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &db, flags, nil)
        guard result == SQLITE_OK, let db else {
            let message = db.map(errorMessage) ?? ("código " + String(result))
            if let db { sqlite3_close_v2(db) }
            throw DatabaseError.open(message)
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 2_000)

        return try body(db)
    }

    private func ensureSchema(_ db: OpaquePointer) throws {
        try execute(db, "PRAGMA foreign_keys = ON")
        try execute(db, """
            CREATE TABLE IF NOT EXISTS schema_meta (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS game_configurations (
                title_id TEXT PRIMARY KEY NOT NULL,
                env_text TEXT NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS game_settings (
                title_id TEXT NOT NULL,
                key TEXT NOT NULL,
                value TEXT NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (title_id, key),
                FOREIGN KEY (title_id) REFERENCES game_configurations(title_id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS game_settings_key_idx ON game_settings(key);
            INSERT OR IGNORE INTO schema_meta(key, value) VALUES ('schema_version', '1');
            """)
    }

    private func document(_ db: OpaquePointer, titleID: String) throws -> String? {
        let statement = try prepare(db, "SELECT env_text FROM game_configurations WHERE title_id = ?1")
        defer { sqlite3_finalize(statement) }
        try bind(titleID, at: 1, to: statement)
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW:
            guard let value = sqlite3_column_text(statement, 0) else { return "" }
            return String(cString: value)
        case SQLITE_DONE:
            return nil
        default:
            throw DatabaseError.step(errorMessage(db))
        }
    }

    private func store(_ db: OpaquePointer, titleID: String, rawText: String, env: EnvFile) throws {
        try execute(db, "BEGIN IMMEDIATE")
        do {
            let now = Date().timeIntervalSince1970
            let upsert = try prepare(db, """
                INSERT INTO game_configurations(title_id, env_text, updated_at)
                VALUES (?1, ?2, ?3)
                ON CONFLICT(title_id) DO UPDATE SET
                    env_text = excluded.env_text,
                    updated_at = excluded.updated_at
                """)
            defer { sqlite3_finalize(upsert) }
            try bind(titleID, at: 1, to: upsert)
            try bind(rawText, at: 2, to: upsert)
            try bind(now, at: 3, to: upsert)
            try step(upsert, db: db)

            let delete = try prepare(db, "DELETE FROM game_settings WHERE title_id = ?1")
            defer { sqlite3_finalize(delete) }
            try bind(titleID, at: 1, to: delete)
            try step(delete, db: db)

            let insert = try prepare(db, """
                INSERT INTO game_settings(title_id, key, value, updated_at)
                VALUES (?1, ?2, ?3, ?4)
                """)
            defer { sqlite3_finalize(insert) }
            for (key, value) in env.effective.sorted(by: { $0.key < $1.key }) {
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
                try bind(titleID, at: 1, to: insert)
                try bind(key, at: 2, to: insert)
                try bind(value, at: 3, to: insert)
                try bind(now, at: 4, to: insert)
                try step(insert, db: db)
            }

            try execute(db, "COMMIT")
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? errorMessage(db)
            if let message { sqlite3_free(message) }
            throw DatabaseError.sql(text)
        }
    }

    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw DatabaseError.sql(errorMessage(db))
        }
        return statement
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, Self.transient) == SQLITE_OK else {
            throw DatabaseError.bind("texto en parámetro " + String(index))
        }
    }

    private func bind(_ value: Double, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw DatabaseError.bind("número en parámetro " + String(index))
        }
    }

    private func step(_ statement: OpaquePointer, db: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.step(errorMessage(db))
        }
    }

    private func errorMessage(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }

    private func writeRaw(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
