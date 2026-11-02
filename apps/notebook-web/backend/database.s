package database

from orm.sqlite3 import pool
from models import Account, Identity, Project, Membership, NotebookImport
from schema import migrate
from catalog import Catalog

export open

def open(path, migrations: "./db/migrations"):
  fs.mkdir_p(fs.Path(path).parent)
  database = pool(path, min_size: 1, max_size: 4, busy_timeout: 2.0, checkout_timeout: 0.5,
    pragmas: {foreign_keys: true, journal_mode: :wal})
  try:
    migrate(database, directory: migrations)
    database.bind!(Account, Identity, Project, Membership, NotebookImport).or_raise
    (database, Catalog(database))
  rescue Exception |error|:
    database.close!
    raise error
