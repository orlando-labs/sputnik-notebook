CREATE TABLE public_sessions (
  id TEXT PRIMARY KEY NOT NULL,
  principal TEXT NOT NULL,
  command_id TEXT NOT NULL,
  template_id TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  core_project_id TEXT NOT NULL UNIQUE,
  created INTEGER NOT NULL,
  expires INTEGER NOT NULL,
  closed INTEGER NOT NULL DEFAULT 0,
  UNIQUE(principal, command_id)
);
CREATE INDEX public_sessions_principal ON public_sessions(principal, created);
CREATE INDEX public_sessions_admission ON public_sessions(closed, expires);
