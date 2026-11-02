package production_seed

# Test-only: seed a disposable local catalog and encode a session with the
# operator's test secret. Never imported by backend/main or deployed with it.
import "../backend/database" as database
import orbit.session as sessions

export main

def main():
  parser = ArgParser()
  parser.arg("--database", required: true)
  parser.arg("--session-secret", required: true)
  args = parser.parse_or_raise
  opened = database.open(args[:database])
  try:
    account = opened[1].sign_in("github", "deployment-probe", "deployment-probe", name: "Local deployment probe")
    now = Time.now.unix_seconds
    entry = sessions.Entry(SecureRandom.hex(32), 1, {account_id: account[:id]}, now, now, now + 3600)
    middleware = sessions.Middleware(store: sessions.CookieStore(), secret: args[:session_secret], secure: true)
    cookie = middleware._save(null, entry, now).split(";")[0]
    print Json.generate({account_id: account[:id], cookie: cookie})
  ensure:
    opened[0].close!
