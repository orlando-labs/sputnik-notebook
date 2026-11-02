CREATE TABLE preview_sessions (
  id TEXT PRIMARY KEY NOT NULL,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  template_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  core_project_id TEXT NOT NULL UNIQUE,
  expires INTEGER NOT NULL
);
