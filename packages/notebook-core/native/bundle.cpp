#include "runtime/sputnik_ext.h"
#if __has_include(<archive.h>)
#include <archive.h>
#include <archive_entry.h>
#elif __has_include("/opt/homebrew/opt/libarchive/include/archive.h")
#include "/opt/homebrew/opt/libarchive/include/archive.h"
#include "/opt/homebrew/opt/libarchive/include/archive_entry.h"
#elif __has_include("/usr/local/opt/libarchive/include/archive.h")
#include "/usr/local/opt/libarchive/include/archive.h"
#include "/usr/local/opt/libarchive/include/archive_entry.h"
#else
#error "Notebook ZIP transport requires the libarchive development headers."
#endif
#include <algorithm>
#include <array>
#include <cerrno>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr std::size_t MiB = 1024U * 1024U;
constexpr std::size_t MaxArchive = 80U * MiB, MaxFiles = 2049;
using Entry = std::pair<std::string, std::string>;
using Entries = std::vector<Entry>;
void require(bool value) { if (!value) throw std::runtime_error("invalid notebook bundle"); }
bool utf8(const std::string &text) {
  for (std::size_t i = 0; i < text.size();) {
    auto c = static_cast<unsigned char>(text[i++]); if (c < 0x80) continue;
    unsigned count, value, minimum;
    if (c >= 0xc2 && c <= 0xdf) { count = 1; value = c & 31; minimum = 0x80; }
    else if (c >= 0xe0 && c <= 0xef) { count = 2; value = c & 15; minimum = 0x800; }
    else if (c >= 0xf0 && c <= 0xf4) { count = 3; value = c & 7; minimum = 0x10000; }
    else return false;
    if (i + count > text.size()) return false;
    while (count--) { c = static_cast<unsigned char>(text[i++]); if ((c & 0xc0) != 0x80) return false; value = (value << 6) | (c & 63); }
    if (value < minimum || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return false;
  }
  return true;
}
std::string text(SputnikCtx *cx, SputnikValue value) {
  const char *data = nullptr; size_t size = 0;
  require(sputnik_str_view(cx, value, &data, &size)); return {data, size};
}
std::string bytes(SputnikCtx *cx, SputnikValue value) {
  const uint8_t *data = nullptr; size_t size = 0;
  require(sputnik_bytes_view(cx, value, &data, &size));
  require(size <= MaxArchive); return {reinterpret_cast<const char *>(data), size};
}
void path(const std::string &name) {
  require(!name.empty() && name.size() <= 1024 && name.front() != '/' && name.back() != '/' && utf8(name));
  for (unsigned char c : name) require(c >= 32 && c != 127 && c != '\\' && c != ':' && c != 0);
  std::size_t start = 0;
  while (start < name.size()) {
    const auto end = name.find('/', start);
    const auto part = name.substr(start, end == std::string::npos ? end : end - start);
    require(!part.empty() && part != "." && part != "..");
    if (end == std::string::npos) break;
    start = end + 1;
  }
}
std::string fold(std::string name) {
  for (char &c : name) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
  return name;
}
Entries normalize(Entries entries) {
  require(!entries.empty() && entries.size() <= MaxFiles);
  std::string prefix;
  const auto root = std::find_if(entries.begin(), entries.end(), [](const auto &e) { return e.first == "project.json"; });
  if (root == entries.end()) {
    const auto slash = entries[0].first.find('/'); require(slash != std::string::npos);
    prefix = entries[0].first.substr(0, slash + 1);
    require(prefix.size() > 13 && prefix.substr(prefix.size() - 13) == ".sputnikbook/");
  }
  std::set<std::string> names;
  std::size_t total = 0;
  bool document = false;
  for (auto &entry : entries) {
    path(entry.first);
    if (!prefix.empty()) { require(entry.first.rfind(prefix, 0) == 0); entry.first.erase(0, prefix.size()); }
    path(entry.first);
    require(names.insert(fold(entry.first)).second);
    if (entry.first == "project.json") { require(!document && entry.second.size() <= 7 * MiB); document = true; }
    else { require(entry.second.size() <= 16 * MiB); total += entry.second.size(); require(total <= 64 * MiB); }
  }
  require(document);
  // A regular file cannot also be the parent directory of another member.
  for (const auto &name : names) for (auto slash = name.find('/'); slash != std::string::npos; slash = name.find('/', slash + 1))
    require(!names.count(name.substr(0, slash)));
  std::sort(entries.begin(), entries.end());
  return entries;
}
Entries from_values(SputnikCtx *cx, SputnikValue value) {
  require(sputnik_is_list(cx, value) && sputnik_list_len(cx, value) <= MaxFiles);
  Entries entries;
  for (size_t i = 0; i < sputnik_list_len(cx, value); ++i) {
    const auto pair = sputnik_list_at(cx, value, i);
    require(sputnik_is_list(cx, pair) && sputnik_list_len(cx, pair) == 2);
    entries.emplace_back(text(cx, sputnik_list_at(cx, pair, 0)), bytes(cx, sputnik_list_at(cx, pair, 1)));
  }
  return normalize(std::move(entries));
}
SputnikValue to_values(SputnikCtx *cx, const Entries &entries) {
  std::vector<SputnikValue> result;
  for (const auto &[name, data] : entries) {
    SputnikValue pair[] = {sputnik_make_str(cx, name.data(), name.size()), sputnik_make_bytes(cx, reinterpret_cast<const uint8_t *>(data.data()), data.size())};
    result.push_back(sputnik_make_list(cx, pair, 2));
  }
  return sputnik_make_list(cx, result.data(), result.size());
}
la_ssize_t append_archive(struct archive *a, void *context, const void *data, size_t size) {
  auto &out = *static_cast<std::string *>(context);
  if (size > MaxArchive - out.size()) { archive_set_error(a, EFBIG, "notebook archive exceeds size limit"); return -1; }
  try { out.append(static_cast<const char *>(data), size); return size; }
  catch (...) { archive_set_error(a, ENOMEM, "cannot allocate notebook archive"); return -1; }
}
}

// Validate canonical transport before the SDK decoder. No I/O or recursive
// regex is needed, even for a full 80 MiB archive payload.
extern "C" SputnikStatus nb_core_book_base64(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
  try {
    require(argc == 1); const auto input = text(cx, args[0]);
    bool valid = input.size() <= ((MaxArchive + 2) / 3) * 4 && input.size() % 4 == 0;
    std::size_t padding = 0;
    if (!input.empty() && input.back() == '=') { padding = 1; if (input.size() > 1 && input[input.size() - 2] == '=') padding = 2; }
    auto digit = [](unsigned char c) -> int {
      if (c >= 'A' && c <= 'Z') return c - 'A';
      if (c >= 'a' && c <= 'z') return c - 'a' + 26;
      if (c >= '0' && c <= '9') return c - '0' + 52;
      return c == '+' ? 62 : c == '/' ? 63 : -1;
    };
    for (std::size_t i = 0; valid && i < input.size() - padding; ++i) valid = digit(input[i]) >= 0;
    if (valid && padding) valid = input.size() >= 4 && (digit(input[input.size() - padding - 1]) & (padding == 2 ? 15 : 3)) == 0;
    *out = sputnik_make_bool(cx, valid); return SPUTNIK_OK;
  } catch (...) { return sputnik_fault(cx, "ValueError", "Cannot validate notebook transport."); }
}

extern "C" SputnikStatus nb_core_book_entries(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
  try { require(argc == 1); *out = to_values(cx, from_values(cx, args[0])); return SPUTNIK_OK; }
  catch (...) { return sputnik_fault(cx, "ValueError", "Invalid notebook members, paths or size limits."); }
}
extern "C" SputnikStatus nb_core_book_text(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
  try {
    require(argc == 1); const auto value = bytes(cx, args[0]);
    *out = utf8(value) && value.find('\0') == std::string::npos ? sputnik_make_str(cx, value.data(), value.size()) : sputnik_make_null(cx);
    return SPUTNIK_OK;
  } catch (...) { return sputnik_fault(cx, "ValueError", "Cannot decode file text."); }
}
extern "C" SputnikStatus nb_core_book_read(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
  try {
    require(argc == 1); const auto input = bytes(cx, args[0]); require(!input.empty());
    std::unique_ptr<struct archive, decltype(&archive_read_free)> a(archive_read_new(), archive_read_free);
    require(bool(a)); require(archive_read_support_format_zip(a.get()) == ARCHIVE_OK);
    require(archive_read_open_memory(a.get(), input.data(), input.size()) == ARCHIVE_OK);
    Entries entries; std::size_t total = 0, count = 0;
    struct archive_entry *entry = nullptr;
    int status;
    while ((status = archive_read_next_header(a.get(), &entry)) == ARCHIVE_OK) {
      require(++count <= MaxFiles * 2);
      const char *raw = archive_entry_pathname_utf8(entry); require(raw != nullptr);
      std::string name(raw);
      require(!archive_entry_symlink(entry) && !archive_entry_hardlink(entry) && archive_entry_is_encrypted(entry) <= 0);
      if (archive_entry_filetype(entry) == AE_IFDIR) {
        require(!name.empty()); if (name.back() == '/') name.pop_back(); path(name);
        require(archive_entry_size(entry) == 0); continue;
      }
      require(archive_entry_filetype(entry) == AE_IFREG);
      path(name); require(entries.size() < MaxFiles);
      if (name.rfind("__MACOSX/", 0) == 0 || name == ".DS_Store") { require(archive_read_data_skip(a.get()) == ARCHIVE_OK); continue; }
      const auto expected = archive_entry_size(entry); require(expected >= 0 && expected <= 16 * MiB);
      std::string data; std::array<char, 65536> buffer;
      for (;;) {
        const auto size = archive_read_data(a.get(), buffer.data(), buffer.size());
        require(size >= 0); if (!size) break;
        require(static_cast<std::size_t>(size) <= 16 * MiB - data.size());
        data.append(buffer.data(), size); total += size; require(total <= 71 * MiB);
      }
      require(data.size() == static_cast<std::size_t>(expected));
      entries.emplace_back(std::move(name), std::move(data));
    }
    require(status == ARCHIVE_EOF && archive_read_close(a.get()) == ARCHIVE_OK);
    *out = to_values(cx, normalize(std::move(entries))); return SPUTNIK_OK;
  } catch (...) { return sputnik_fault(cx, "ValueError", "Invalid notebook ZIP, unsafe members or exceeded size limits."); }
}
extern "C" SputnikStatus nb_core_book_pack(SputnikCtx *cx, const SputnikValue *args, size_t argc, SputnikValue *out) {
  try {
    require(argc == 1); const auto entries = from_values(cx, args[0]);
    std::unique_ptr<struct archive, decltype(&archive_write_free)> a(archive_write_new(), archive_write_free);
    require(bool(a)); require(archive_write_set_format_zip(a.get()) == ARCHIVE_OK);
    require(archive_write_set_bytes_per_block(a.get(), 0) == ARCHIVE_OK);
    std::string data;
    require(archive_write_open(a.get(), &data, nullptr, append_archive, nullptr) == ARCHIVE_OK);
    for (const auto &[name, content] : entries) {
      std::unique_ptr<struct archive_entry, decltype(&archive_entry_free)> entry(archive_entry_new(), archive_entry_free);
      require(bool(entry)); const auto member = "Notebook.sputnikbook/" + name;
      archive_entry_set_pathname_utf8(entry.get(), member.c_str());
      archive_entry_set_filetype(entry.get(), AE_IFREG); archive_entry_set_perm(entry.get(), 0644);
      archive_entry_set_mtime(entry.get(), 0, 0); archive_entry_set_size(entry.get(), content.size());
      require(archive_write_header(a.get(), entry.get()) == ARCHIVE_OK);
      if (!content.empty()) require(archive_write_data(a.get(), content.data(), content.size()) == static_cast<la_ssize_t>(content.size()));
      require(archive_write_finish_entry(a.get()) == ARCHIVE_OK);
    }
    require(archive_write_close(a.get()) == ARCHIVE_OK);
    *out = sputnik_make_bytes(cx, reinterpret_cast<const uint8_t *>(data.data()), data.size()); return SPUTNIK_OK;
  } catch (...) { return sputnik_fault(cx, "ValueError", "Cannot export notebook ZIP: invalid members or exceeded size limits."); }
}
