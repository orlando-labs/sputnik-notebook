package notebook.core.package_index

export remember_package, package_requirements_index

def package_part?(part):
  return false if part == "" or part.bytes.count > 128 or part.contains?("..")
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".contains?(part[0]) and part.contains_only?("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

def package_name?(name):
  parts = name.split("/")
  not name.ends_with?("/") and parts.count <= 2 and parts.all?: package_part?($it)

def remember_package(requirements, name, version):
  return unless package_name?(name)
  requirements[name] = version if package_part?(version)
  requirements[name] = "" unless requirements.has_key?(name)

def package_requirements_index(packages, existing: ""):
  requirements = {}
  existing.split("\n").each |line|:
    parts = line.split("\t")
    remember_package(requirements, parts[0], parts[1]) if parts.count == 2
  packages.each |item|: remember_package(requirements, item[:name], item[:version])
  lines = requirements.keys.sorted.map |name|: name + "\t" + requirements[name] + "\n"
  lines.join("")
