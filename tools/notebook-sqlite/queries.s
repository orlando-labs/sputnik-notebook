package rows_db

import sqlite3

export fetch_page, overview, summarize

# Only these three identifiers can enter SQL. Values always use bind parameters.
def _table(name):
  unless ["Строка 1", "Строка 2", "Строка 3"].include?(name):
    raise ArgumentError("Выберите Строка 1, Строка 2 или Строка 3")
  sqlite3.quote_identifier(name)

def _projection(name):
  common = '"Код строки", "Полный номер наряда" AS "Наряд", trim("Код наряда/заказ") AS "Заказ", "Дата", "ВесИтого" AS "Вес"'
  if name == "Строка 1":
    common + ', "КоличествоМарок" AS "Количество", "Изделие", "Отделение"'
  else if name == "Строка 2":
    common + ', "Количество", "Код детали/Название детали" AS "Деталь", "Сотрамент" AS "Сортамент"'
  else:
    common + ', "Количество", "Код детали/Название детали" AS "Деталь", "Этап"'

def _where(search):
  if search == "":
    ""
  else:
    # instr treats %, _ and quotes literally; there is no executable interpolation.
    ' WHERE instr(COALESCE("Код наряда/заказ", \'\'), ?) > 0 OR instr(CAST("Полный номер наряда" AS TEXT), ?) > 0'

def _params(search):
  if search == "": [] else: [search, search]

def fetch_page(path, name, search, requested_page, page_size):
  table = _table(name)
  if page_size < 1 or page_size > 500 or requested_page < 1:
    raise ArgumentError("Размер страницы: 1–500; номер страницы: от 1")
  predicate = _where(search)
  binds = _params(search)
  sqlite3.open(path, mode: :readonly, busy_timeout: 2.seconds) |db|:
    # Count and page come from a single consistent read snapshot.
    db.transaction |tx|:
      total = tx.scalar("SELECT count(*) FROM " + table + predicate, params: binds)
      pages = if total == 0: 1 else: (total + page_size - 1).divmod(page_size)[0]
      page = if requested_page > pages: pages else: requested_page
      offset = (page - 1) * page_size
      query = "SELECT " + _projection(name) + " FROM " + table + predicate + " ORDER BY rowid LIMIT ? OFFSET ?"
      rows = tx.query(query, params: binds + [page_size, offset])
      columns = ["Код строки", "Наряд", "Заказ", "Дата", "Вес", "Количество"]
      if name == "Строка 1":
        columns = columns + ["Изделие", "Отделение"]
      else if name == "Строка 2":
        columns = columns + ["Деталь", "Сортамент"]
      else:
        columns = columns + ["Деталь", "Этап"]
      {rows: rows, columns: columns, total: total, pages: pages, page: page, loaded: rows.count, readonly: db.readonly?()}

def overview(path):
  sqlite3.open(path, mode: :readonly) |db|:
    ["Строка 1", "Строка 2", "Строка 3"].map |name|:
      count = db.scalar("SELECT count(*) FROM " + _table(name))
      {"Таблица": name, "Строк в базе": count}

def summarize(path, name, search):
  table = _table(name)
  sqlite3.open(path, mode: :readonly, busy_timeout: 2.seconds) |db|:
    # Aggregation runs in SQLite over ALL matching rows, independent of the page.
    db.query('SELECT trim("Код наряда/заказ") AS "Заказ", count(*) AS "Строк", sum("ВесИтого") AS "Вес" FROM ' + table + _where(search) + ' GROUP BY trim("Код наряда/заказ") ORDER BY count(*) DESC, trim("Код наряда/заказ") LIMIT 15', params: _params(search))
