#!/usr/bin/env python3
"""Prepare SQLite's native notebook dependency and create the Строки example."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
DEFINES = ["SQLITE_THREADSAFE=1", "SQLITE_ENABLE_COLUMN_METADATA=1", "SQLITE_ENABLE_FTS5=1",
           "SQLITE_ENABLE_JSON1=1", "SQLITE_DQS=0", "SQLITE_OMIT_LOAD_EXTENSION=1"]
SHIM = b'#include "runtime/sputnik_ext.h"\nuint32_t sputnik_ext_abi_version(void) { return SPUTNIK_EXT_ABI_VERSION; }\n'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def prepare(package, language):
    """Publish an immutable source/library generation; never load or execute it."""
    compiler = shlex.split(os.environ.get("CC", "cc"))
    compiler_version = subprocess.check_output(compiler + ["--version"])
    sources = {name: (package / name).read_bytes() for name in
               ["src/sqlite3.s", "native/sqlite3_ext.c", "native/sqlite3.c", "native/sqlite3.h"]}
    sources["include/runtime/sputnik_ext.h"] = (language / "runtime/sputnik_ext.h").read_bytes()
    sources["abi.c"] = SHIM
    manifest = {"schema": "sputnik.build.v1", "name": "sqlite3", "root": "sqlite3",
                "profiles": {"required": ["core.v1", "ffi.v1", "macro.v1"]},
                "modules": [{"name": "sqlite3", "path": "src/sqlite3.s"}],
                "native_extensions": [{"name": "sqlite3", "language": "c",
                    "sources": ["native/sqlite3_ext.c", "native/sqlite3.c", "abi.c"],
                    "headers": ["native/sqlite3.h"], "defines": DEFINES}]}
    sources["sputnik.build.json"] = (json.dumps(manifest, sort_keys=True) + "\n").encode()
    flags = ["-O2", "-fPIC"] + ["-D" + d for d in DEFINES]
    flags += ["-dynamiclib", "-undefined", "dynamic_lookup"] if platform.system() == "Darwin" else ["-shared"]
    key = digest(compiler_version + repr((compiler, flags, platform.machine(), platform.system())).encode() +
                 b"".join(name.encode() + b"\0" + data for name, data in sorted(sources.items())))
    parent = package / "out/notebook"
    parent.mkdir(parents=True, exist_ok=True)
    generation = parent / key
    library_name = "libsqlite3_notebook.dylib" if platform.system() == "Darwin" else "libsqlite3_notebook.so"
    if not generation.exists():
        with tempfile.TemporaryDirectory(prefix=".prepare-", dir=parent) as temporary:
            staging = Path(temporary) / "generation"
            staging.mkdir()
            for name, data in sources.items():
                target = staging / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            print("Preparing SQLite native package…", flush=True)
            subprocess.run(compiler + flags + ["-Iinclude", "native/sqlite3_ext.c", "native/sqlite3.c",
                           "abi.c", "-lpthread", "-lm", "-o", library_name], cwd=staging, check=True)
            hashes = {name: digest(data) for name, data in sources.items()}
            hashes[library_name] = digest((staging / library_name).read_bytes())
            write_json(staging / "hashes.json", hashes)
            staging.rename(generation)
    hashes = json.loads((generation / "hashes.json").read_text())
    for name, data in sources.items():
        if (generation / name).read_bytes() != data:
            raise ValueError(f"Prepared source changed: {generation / name}")
    library = generation / library_name
    if digest(library.read_bytes()) != hashes[library_name]:
        raise ValueError(f"Prepared library changed: {library}")
    return {"path": str(package), "auto_import": False,
            "manifest": str((generation / "sputnik.build.json").relative_to(package)),
            "native_library": str(library.relative_to(package)), "native_sha256": hashes[library_name]}


def create(output, database, package, language):
    if output.exists():
        raise FileExistsError(f"Refusing to replace existing notebook: {output}")
    database = database.resolve(strict=True)
    dependency = prepare(package.resolve(), language.resolve())
    dependency["path"] = os.path.relpath(package.resolve(), output.resolve())
    cell = lambda id, kind, source: {"id": str(id), "kind": kind, "mode": "manual", "source": source}
    cells = [
        cell(1, "text", "Строки · SQLite\nЖивая выборка из внешней базы. Откройте доску «Обзор базы» и нажмите Run Sheet. Файл открывается только для чтения. Результаты не сохраняются в документе."),
        cell(2, "code", '''import rows_db
from notebook.ui import DataTableView
db_path = notebook.input("database")
table_name = notebook.input("table")
search = notebook.input("search")
page_size = notebook.input("page_size")
requested_page = notebook.input("page")
page_data = rows_db.fetch_page(db_path, table_name, search, requested_page, page_size)
matching_rows = page_data[:total]
page_count = page_data[:pages]
current_page = page_data[:page]
loaded_rows = page_data[:loaded]
readonly = page_data[:readonly]
print("#{table_name}: #{loaded_rows} / #{matching_rows}; страница #{current_page} / #{page_count}; read-only=#{readonly}")
table_view = DataTableView(page_data[:rows], columns: page_data[:columns])
notebook.show(table_view, id: "rows", caption: "Строки из SQLite")
loaded_rows
'''),
        cell(3, "text", "{{table_name}} · найдено {{matching_rows}} строк · загружено {{loaded_rows}} · страница {{current_page}} / {{page_count}}\nПоиск выше выполняется SQL по всей выбранной таблице. Filter rows, сортировка и экспорт в Data Table относятся только к загруженной странице. При новом поиске задайте страницу 1; выход за последнюю страницу автоматически ограничивается."),
        cell(4, "code", 'import rows_db\nfrom notebook.ui import DataTableView\nnotebook.show(DataTableView(rows_db.overview(db_path), columns: ["Таблица", "Строк в базе"]), id: "inventory", caption: "Таблицы базы")\nnull\n'),
        cell(5, "code", 'import rows_db\nfrom notebook.ui import DataTableView\nnotebook.show(DataTableView(rows_db.summarize(db_path, table_name, search), columns: ["Заказ", "Строк", "Вес"]), id: "orders", caption: "Топ-15 заказов")\nnull\n'),
        cell(6, "text", "Как это устроено\nrows_db.fetch_page открывает соединение sqlite3.open(path, mode: :readonly), считает совпадения и делает SELECT … ORDER BY rowid LIMIT ? OFFSET ? в одной транзакции чтения. Возвращает список Map; DataTableView задаёт представление, а notebook.show публикует его независимо от результата ячейки. Соединение закрывается до отрисовки. Название таблицы выбирается из трёх разрешённых значений, поисковый текст и пагинация передаются параметрами.\nСводка по заказам считается в SQLite по всем совпадениям, а не по одной странице. Даты в исходной базе — текст ДД.ММ.ГГГГ; лексикографическая сортировка даты не даёт хронологического порядка. Значения веса показаны в единицах исходной базы.")
    ]
    options = lambda values: [{"label": str(v), "value_json": json.dumps(v, ensure_ascii=False)} for v in values]
    inputs = [
        {"id": "database", "title": "Файл SQLite", "type": "string", "default": str(database)},
        {"id": "table", "title": "Таблица", "type": "string", "default": "Строка 1"},
        {"id": "search", "title": "Наряд или заказ — содержит", "type": "string", "default": ""},
        {"id": "page_size", "title": "Строк на странице", "type": "integer", "default": 100, "minimum": 1, "maximum": 500},
        {"id": "page", "title": "Страница", "type": "integer", "default": 1, "minimum": 1, "maximum": 1000000}
    ]
    components = [
        {"id": "intro", "kind": "rich_text", "title": "SQLite / Data Table", "row": "intro", "span": 12,
         "text_mode": "markdown", "text_content": {"source": "# Строки · SQLite\nВнешняя база → SQL в worker → строки результата → Data Table. **Только чтение.**"}},
        {"id": "file", "kind": "file_input", "title": "База данных", "input": "database", "row": "file", "span": 12, "p1": {"extensions": "sqlite3,sqlite,db"}},
        {"id": "query", "kind": "parameter_form", "title": "Запрос к базе · Apply, затем Run Sheet", "row": "query", "span": 8,
         "fields": [{"input": "table", "control": {"style": "select", "options": options(["Строка 1", "Строка 2", "Строка 3"])}},
                    {"input": "search"}, {"input": "page_size", "control": {"style": "select", "options": options([25, 50, 100, 250, 500])}},
                    {"input": "page", "control": {"style": "stepper", "step": 1}}]},
        {"id": "run", "kind": "execution_controls", "title": "Выполнить запросы", "row": "query", "span": 4, "p1": {"target_kind": "sheet"}},
        {"id": "found", "kind": "metric", "title": "Найдено в базе", "cell": "2", "binding": "matching_rows", "row": "metrics", "span": 4},
        {"id": "loaded", "kind": "metric", "title": "Загружено строк", "cell": "2", "binding": "loaded_rows", "row": "metrics", "span": 4},
        {"id": "pages", "kind": "metric", "title": "Всего страниц", "cell": "2", "binding": "page_count", "row": "metrics", "span": 4},
        {"id": "page_note", "kind": "rich_text", "title": "Область данных", "row": "note", "span": 12,
         "text_mode": "markdown", "text_content": {"source": "**{{table_name}}** · страница **{{current_page}} / {{page_count}}**\nПоиск в параметрах — по всей таблице. Filter rows, сортировка и экспорт ниже — по загруженной странице."}},
        {"id": "rows", "kind": "table", "title": "Строки из SQLite", "cell": "2", "table_id": "rows", "row": "data", "span": 12},
        {"id": "inventory", "kind": "table", "title": "Таблицы базы", "cell": "4", "table_id": "inventory", "row": "summary", "span": 4},
        {"id": "orders", "kind": "table", "title": "Топ-15 заказов · все совпадения", "cell": "5", "table_id": "orders", "row": "summary", "span": 8}
    ]
    document = {"format": "sputnik-notebook", "version": 3, "title": "Строки · SQLite", "active_sheet": "main",
                "sheets": [{"id": "main", "title": "Запросы SQLite", "cells": cells}],
                "modules": [{"id": "rows_db", "path": "modules/rows_db.s"}], "auto_imports": [], "inputs": inputs,
                "boards": [{"id": "database", "title": "Обзор базы", "sheet": "main", "columns": 1,
                            "rows": [{"id": r} for r in ["intro", "file", "query", "metrics", "note", "data", "summary"]],
                            "components": components}], "dependencies": [dependency,
                    {"path": os.path.relpath(language.resolve() / "packages/notebook_ui", output.resolve()), "auto_import": False}]}
    output.mkdir(parents=True)
    try:
        (output / "modules").mkdir()
        shutil.copyfile(ROOT / "tools/notebook-sqlite/queries.s", output / "modules/rows_db.s")
        write_json(output / "project.json", document)
    except Exception:
        shutil.rmtree(output)
        raise
    return output.resolve()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--database", required=True, type=Path)
    parser.add_argument("--sqlite-package", type=Path, default=ROOT.parent / "sqlite3")
    parser.add_argument("--sputnik-root", type=Path, default=ROOT.parent / "sputnik-lang")
    args = parser.parse_args()
    print(create(args.output, args.database, args.sqlite_package, args.sputnik_root))
