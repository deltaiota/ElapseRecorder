import Foundation
import GRDB

/// The single V2 database pool. GRDB serializes writers while allowing bounded concurrent reads.
final nonisolated class ElapseDatabase: Sendable {
    let pool: DatabasePool

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var configuration = Configuration()
        configuration.label = "ElapseRecorder.V2"
        configuration.busyMode = .timeout(5)
        configuration.maximumReaderCount = 5
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }

        pool = try DatabasePool(path: url.path(percentEncoded: false), configuration: configuration)
        var migrator = Self.migrator
        migrator.eraseDatabaseOnSchemaChange = false
        try migrator.migrate(pool)
    }

    func appliedMigrationIdentifiers() async throws -> [String] {
        try await pool.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
    }

    func schemaTableNames() async throws -> [String] {
        try await pool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
            )
        }
    }

    func schemaIndexNames() async throws -> [String] {
        try await pool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%' ORDER BY name"
            )
        }
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(CaptureDatabaseSchema.migrationV1) { db in
            try db.execute(sql: """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY NOT NULL,
                bundle_identifier TEXT NOT NULL,
                display_name TEXT NOT NULL,
                process_identifier INTEGER NOT NULL,
                started_at REAL NOT NULL,
                ended_at REAL,
                state TEXT NOT NULL CHECK (state IN ('open', 'closed', 'tombstoned')),
                CHECK ((state = 'open' AND ended_at IS NULL)
                    OR (state IN ('closed', 'tombstoned') AND ended_at IS NOT NULL))
            )
            """)
            try db.execute(sql: """
            CREATE TABLE windows (
                id TEXT PRIMARY KEY NOT NULL,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                system_window_id INTEGER NOT NULL,
                display_number INTEGER NOT NULL CHECK (display_number > 0),
                label TEXT,
                first_seen_at REAL NOT NULL,
                last_seen_at REAL NOT NULL,
                UNIQUE (session_id, display_number)
            )
            """)
            try db.execute(sql: """
            CREATE TABLE title_observations (
                id TEXT PRIMARY KEY NOT NULL,
                window_id TEXT NOT NULL REFERENCES windows(id) ON DELETE CASCADE,
                title TEXT,
                observed_at REAL NOT NULL
            )
            """)
            try db.execute(sql: """
            CREATE TABLE media_assets (
                id TEXT PRIMARY KEY NOT NULL,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                window_id TEXT NOT NULL REFERENCES windows(id) ON DELETE CASCADE,
                kind TEXT NOT NULL CHECK (kind IN ('spoolImage', 'videoSegment')),
                state TEXT NOT NULL CHECK (state IN ('writing', 'ready', 'failed')),
                path TEXT NOT NULL UNIQUE,
                byte_count INTEGER NOT NULL DEFAULT 0 CHECK (byte_count >= 0),
                pixel_width INTEGER NOT NULL DEFAULT 0 CHECK (pixel_width >= 0),
                pixel_height INTEGER NOT NULL DEFAULT 0 CHECK (pixel_height >= 0),
                frame_count INTEGER NOT NULL DEFAULT 0 CHECK (frame_count >= 0),
                created_at REAL NOT NULL,
                ready_at REAL,
                failure_message TEXT
            )
            """)
            try db.execute(sql: """
            CREATE TABLE frames (
                id TEXT PRIMARY KEY NOT NULL,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                window_id TEXT NOT NULL REFERENCES windows(id) ON DELETE CASCADE,
                asset_id TEXT NOT NULL REFERENCES media_assets(id) ON DELETE CASCADE,
                asset_frame_index INTEGER,
                asset_pts_value INTEGER,
                asset_pts_timescale INTEGER,
                captured_at REAL NOT NULL,
                spool_path TEXT NOT NULL,
                image_format TEXT NOT NULL CHECK (image_format IN ('heic', 'png')),
                pixel_width INTEGER NOT NULL DEFAULT 0 CHECK (pixel_width >= 0),
                pixel_height INTEGER NOT NULL DEFAULT 0 CHECK (pixel_height >= 0),
                perceptual_hash INTEGER NOT NULL DEFAULT 0,
                process_identifier INTEGER NOT NULL DEFAULT 0,
                generation INTEGER NOT NULL DEFAULT 0,
                cycle_sequence INTEGER NOT NULL DEFAULT 0 CHECK (cycle_sequence >= 0),
                scheduled_offset_nanoseconds INTEGER NOT NULL DEFAULT 0 CHECK (scheduled_offset_nanoseconds >= 0),
                request_started_at REAL NOT NULL,
                completed_at REAL NOT NULL,
                CHECK ((asset_pts_value IS NULL AND asset_pts_timescale IS NULL)
                    OR (asset_pts_value IS NOT NULL AND asset_pts_timescale IS NOT NULL AND asset_pts_timescale > 0)),
                UNIQUE (asset_id, asset_frame_index)
            )
            """)
            try db.execute(sql: """
            CREATE TABLE unavailable_spans (
                id TEXT PRIMARY KEY NOT NULL,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                started_at REAL NOT NULL,
                ended_at REAL NOT NULL,
                reason TEXT NOT NULL
            )
            """)
            try db.execute(sql: """
            CREATE TABLE segment_jobs (
                id TEXT PRIMARY KEY NOT NULL,
                asset_id TEXT NOT NULL UNIQUE REFERENCES media_assets(id) ON DELETE CASCADE,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                window_id TEXT NOT NULL REFERENCES windows(id) ON DELETE CASCADE,
                partial_path TEXT NOT NULL UNIQUE,
                final_path TEXT NOT NULL UNIQUE,
                canvas_width INTEGER NOT NULL CHECK (canvas_width > 0),
                canvas_height INTEGER NOT NULL CHECK (canvas_height > 0),
                state TEXT NOT NULL CHECK (state IN ('queued', 'leased', 'failed', 'published', 'committed')),
                lease_worker_id TEXT,
                lease_expires_at REAL,
                retry_at REAL,
                failure_message TEXT,
                created_at REAL NOT NULL,
                committed_at REAL,
                CHECK ((state = 'leased' AND lease_worker_id IS NOT NULL AND lease_expires_at IS NOT NULL)
                    OR state <> 'leased')
            )
            """)
            try db.execute(sql: """
            CREATE TABLE segment_job_frames (
                job_id TEXT NOT NULL REFERENCES segment_jobs(id) ON DELETE CASCADE,
                frame_id TEXT NOT NULL UNIQUE REFERENCES frames(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
                pts_value INTEGER NOT NULL CHECK (pts_value >= 0),
                pts_timescale INTEGER NOT NULL CHECK (pts_timescale > 0),
                PRIMARY KEY (job_id, ordinal)
            )
            """)
            try db.execute(sql: """
            CREATE TABLE storage_deletion_tombstones (
                id TEXT PRIMARY KEY NOT NULL,
                created_at REAL NOT NULL
            )
            """)
            try db.execute(sql: """
            CREATE TABLE storage_deletion_sessions (
                tombstone_id TEXT NOT NULL REFERENCES storage_deletion_tombstones(id) ON DELETE CASCADE,
                session_id TEXT NOT NULL UNIQUE REFERENCES sessions(id) ON DELETE CASCADE,
                PRIMARY KEY (tombstone_id, session_id)
            )
            """)
            try db.execute(sql: """
            CREATE TABLE storage_deletion_files (
                tombstone_id TEXT NOT NULL REFERENCES storage_deletion_tombstones(id) ON DELETE CASCADE,
                path TEXT NOT NULL,
                PRIMARY KEY (tombstone_id, path)
            )
            """)

            try db.execute(sql: "CREATE INDEX sessions_by_app_time ON sessions(bundle_identifier, started_at DESC, id DESC)")
            try db.execute(sql: "CREATE INDEX sessions_by_state_time ON sessions(state, started_at, id)")
            try db.execute(sql: "CREATE INDEX windows_by_session_display ON windows(session_id, display_number, id)")
            try db.execute(sql: "CREATE INDEX titles_by_window_time ON title_observations(window_id, observed_at, id)")
            try db.execute(sql: "CREATE INDEX frames_by_window_time ON frames(window_id, captured_at, id)")
            try db.execute(sql: "CREATE INDEX frames_by_session_time ON frames(session_id, captured_at, id)")
            try db.execute(sql: "CREATE INDEX frames_by_asset ON frames(asset_id, asset_frame_index)")
            try db.execute(sql: "CREATE INDEX frames_by_capture_time ON frames(captured_at, id)")
            try db.execute(sql: "CREATE INDEX frames_by_cycle ON frames(session_id, window_id, cycle_sequence, id)")
            try db.execute(sql: "CREATE INDEX frames_by_format_cycle ON frames(image_format, session_id, window_id, cycle_sequence, id)")
            try db.execute(sql: "CREATE INDEX spans_by_session_time ON unavailable_spans(session_id, started_at, id)")
            try db.execute(sql: "CREATE INDEX assets_by_session_state ON media_assets(session_id, state, created_at, id)")
            try db.execute(sql: "CREATE INDEX assets_by_window_kind ON media_assets(window_id, kind, state, created_at, id)")
            try db.execute(sql: "CREATE INDEX assets_by_kind_state ON media_assets(kind, state, id)")
            try db.execute(sql: "CREATE INDEX jobs_by_state_retry ON segment_jobs(state, retry_at, created_at, id)")
            try db.execute(sql: "CREATE INDEX jobs_by_lease_expiry ON segment_jobs(state, lease_expires_at, id)")
            try db.execute(sql: "CREATE INDEX deletion_sessions_by_tombstone ON storage_deletion_sessions(tombstone_id, session_id)")
            try db.execute(sql: "CREATE INDEX deletion_files_by_tombstone ON storage_deletion_files(tombstone_id, path)")
        }
        migrator.registerMigration(CaptureDatabaseSchema.migrationV2) { db in
            try db.execute(sql: "ALTER TABLE segment_jobs ADD COLUMN cleanup_completed_at REAL")
        }
        migrator.registerMigration(CaptureDatabaseSchema.migrationV3) { db in
            try db.execute(sql: """
            CREATE TABLE backend_imports (
                identifier TEXT PRIMARY KEY NOT NULL,
                completed_at REAL NOT NULL
            )
            """)
        }
        return migrator
    }
}
