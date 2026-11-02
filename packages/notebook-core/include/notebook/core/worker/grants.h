#pragma once
#include "profile/capabilities.h"
#include <algorithm>
#include <sstream>
#include <stdexcept>

namespace sputnik::notebook::worker {
// Host policy only. Never read grants from notebook source or its manifest.
inline std::vector<capability::CapabilityRequest> parse_grants(const std::string &text) {
  if (text.size() > 32768) throw std::invalid_argument("Worker grants exceed 32 KiB");
  std::vector<capability::CapabilityRequest> grants;
  std::istringstream input(text);
  std::string line;
  while (std::getline(input, line)) {
    const auto first = line.find_first_not_of(" \t\r");
    if (first == std::string::npos) continue;
    line = line.substr(first, line.find_last_not_of(" \t\r") - first + 1);
    if (line.size() > 4096 || std::any_of(line.begin(), line.end(), [](unsigned char c) { return c < 32 || c == 127; }))
      throw std::invalid_argument("Invalid control character or oversized worker grant");
    capability::CapabilityRequest grant;
    capability::CapabilityDiagnostic error;
    if (!capability::parse_cli_grant(line, &grant, &error)) throw std::invalid_argument(error.message);
    if (grant.target.empty()) throw std::invalid_argument("Grant target is empty; omit '=' to allow all targets");
    grants.push_back(std::move(grant));
    if (grants.size() > 128) throw std::invalid_argument("At most 128 worker grants are supported");
  }
  std::sort(grants.begin(), grants.end(), [](const auto &a, const auto &b) {
    return capability::request_to_text(a) < capability::request_to_text(b);
  });
  grants.erase(std::unique(grants.begin(), grants.end(), [](const auto &a, const auto &b) {
    return a.name == b.name && a.target == b.target;
  }), grants.end());
  return grants;
}
inline std::string grants_text(const std::vector<capability::CapabilityRequest> &grants) {
  std::string result;
  for (const auto &grant : grants) {
    if (!result.empty()) result += '\n';
    result += capability::request_to_text(grant);
  }
  return result;
}
} // namespace sputnik::notebook::worker
