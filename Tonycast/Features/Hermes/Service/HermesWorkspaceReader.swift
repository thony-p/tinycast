import Foundation

/// Reads the connected Hermes instance's own project list.
///
/// Projects are not on the ACP wire: `session/new` takes a working directory, and nothing in the
/// protocol names a project. Hermes keeps them in a per-profile `projects.db` that its desktop
/// sidebar
/// reads, so the same rows are read here — through the connection's own host, which is why the
/// script
/// travels over `ssh` for the VM and runs locally for this Mac. Reading the file directly would
/// list
/// *this* Mac's projects whichever host the window is attached to.
enum HermesWorkspaceReader {
    /// The script answers with an empty list rather than an error when the store cannot be read, so
    /// a
    /// pane falls back to sessions instead of showing a failure nobody can act on.
    ///
    /// Two failures are handled rather than reported. `mode=ro` is tried first and a plain
    /// connection
    /// second, because Hermes keeps this store in WAL mode and a read-only connection to a WAL
    /// database
    /// whose `-shm` file is absent fails with "unable to open database file". That file exists only
    /// while something holds the database open, so the listing would work while Hermes ran and fail
    /// when it did not. The probe query is what makes the fallback work, since `sqlite3.connect`
    /// opens
    /// nothing and the failure otherwise waits for the first statement.
    static let script = """
        import json, os, sqlite3, sys
        home = os.environ.get("HERMES_HOME") or os.path.join(os.path.expanduser("~"), ".hermes")
        path = os.path.join(home, "projects.db")
        out = {"projects": []}
        db = None
        for uri in ("file:%s?mode=ro" % path, path):
            try:
                candidate = sqlite3.connect(uri, uri=uri.startswith("file:"))
                candidate.execute("select 1 from sqlite_master limit 1")
                db = candidate
                break
            except Exception:
                db = None
        try:
            folders = {}
            for pid, folder in db.execute(
                    "select project_id, path from project_folders "
                    "order by is_primary desc, added_at asc"):
                folders.setdefault(pid, []).append(folder)
            for row in db.execute(
                    "select id, slug, name, coalesce(primary_path, ''), archived "
                    "from projects order by created_at asc"):
                if row[4]:
                    continue
                candidates = ([row[3]] if row[3] else []) + folders.get(row[0], [])
                start = next(
                    (os.path.realpath(os.path.expanduser(c))
                     for c in candidates if os.path.isdir(os.path.expanduser(c))), "")
                out["projects"].append({
                    "id": row[0], "slug": row[1], "name": row[2],
                    "startDirectory": start, "folders": folders.get(row[0], []),
                })
        except Exception:
            out["projects"] = []
        finally:
            if db is not None:
                db.close()
        sys.stdout.write(json.dumps(out))
        """

    nonisolated static func read(_ connection: HermesConnection) async -> [HermesWorkspace] {
        let output = await HermesHostScript.run(connection, script: script, timeout: 20)
        return HermesWorkspace.decodeListing(output)
    }
}
