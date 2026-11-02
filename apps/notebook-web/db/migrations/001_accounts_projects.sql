CREATE TABLE accounts (
  id TEXT PRIMARY KEY NOT NULL,
  name TEXT,
  state TEXT NOT NULL CHECK (state IN ('active', 'disabled')),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE account_identities (
  id TEXT PRIMARY KEY NOT NULL,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  uid TEXT NOT NULL,
  login TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(provider, uid)
);
CREATE INDEX account_identities_account ON account_identities(account_id);
CREATE TABLE projects (
  id TEXT PRIMARY KEY NOT NULL,
  owner_account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE RESTRICT,
  core_project_id TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL CHECK (length(trim(title)) BETWEEN 1 AND 200),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX projects_owner ON projects(owner_account_id);
CREATE TABLE project_memberships (
  id TEXT PRIMARY KEY NOT NULL,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('editor', 'viewer')),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(project_id, account_id)
);
CREATE INDEX project_memberships_account ON project_memberships(account_id);
