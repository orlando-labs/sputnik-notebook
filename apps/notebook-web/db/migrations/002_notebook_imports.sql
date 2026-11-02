CREATE TABLE notebook_imports (
  id TEXT PRIMARY KEY NOT NULL,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  command_id TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  title TEXT NOT NULL,
  project_id TEXT NOT NULL UNIQUE REFERENCES projects(id) ON DELETE CASCADE,
  state TEXT NOT NULL CHECK (state IN ('pending', 'complete')),
  UNIQUE(account_id, command_id)
);
