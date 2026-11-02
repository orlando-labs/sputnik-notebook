package schema

export migrate

# Startup migration is versioned and atomic; no account/project cleanup runs here.
def migrate(database, directory: "./db/migrations"):
  database.with_lock:
    database.with_connection |connection|:
      connection.exec("CREATE TABLE IF NOT EXISTS web_schema_migrations (version TEXT PRIMARY KEY NOT NULL, digest TEXT NOT NULL)")
      paths = fs.entries(directory).map: _1.to_str
      paths.sorted.each |path|:
        next unless path.ends_with?(".sql")
        version = fs.Path(path).basename
        source = fs.read_text(path, limit: 1048576)
        digest = Digest.sha256(source.bytes).hex
        previous = connection.query("SELECT digest FROM web_schema_migrations WHERE version=?", params: [version])
        if previous.present?:
          raise ValueError("applied migration was modified: " + version) unless previous[0][:digest] == digest
        else:
          connection.exec(source)
          connection.execute("INSERT INTO web_schema_migrations(version,digest) VALUES(?,?)", params: [version, digest])
  null
