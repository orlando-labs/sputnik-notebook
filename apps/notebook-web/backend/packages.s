package packages

from models import InvalidInput, WebError, NotFound
from sources import command_id

export Packages

def package_name(value):
  raise InvalidInput("Use a registry package name, not a URL or server path.") unless Str === value and value.length > 0 and value.length <= 257 and value.split("/").count <= 2
  valid = value.split("/").all? |part|:
    part.length > 0 and part != "." and part != ".." and not part.contains?("..") and "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".contains?(part[0]) and part.chars.all? |c|:
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".contains?(c)
  raise InvalidInput("Use a registry package name, not a URL or server path.") unless valid
  value

def bounded(value, label, limit = 256):
  raise InvalidInput("Invalid " + label + ".") unless Str === value and value.length <= limit and not value.starts_with?("-") and not value.chars.any? |c|: c.bytes[0] < 32 or c.bytes[0] == 127
  value

class Packages:
  def init(@catalog, @notebooks, @native = false)

  def job(record):
    {id: record[:id], action: record[:action], state: record[:state],
      message: if record[:state] == "failed" then "The package operation failed on the server. Check the package/version and server registry configuration." else if record[:state] == "interrupted" then "The server restarted during this operation. Inspect the installed packages before trying again." else ""}

  def status(current, id):
    project = @catalog.require_project(current, id)
    source = @notebooks.call("dependency.status", {project_id: project[:core_project_id]})
    {can_manage: @catalog.role(current, project) == "owner", native_allowed: @native,
      packages: source[:packages].map |item|: {name: item[:name], display_name: item[?:display_name] or item[:name], version: item[:version], variant: item[?:variant], digest: item[:digest]},
      jobs: source[:jobs].map: job($it)}

  def read(current, id, operation):
    project = @catalog.require_project(current, id)
    record = @notebooks.call("dependency.get", {project_id: project[:core_project_id], operation_id: command_id(operation)})
    raise NotFound() unless record[:project] == project[:core_project_id]
    {job: job(record)}

  def catalog(current, id, name, version):
    project = @catalog.require_project(current, id)
    query = if version == null then "versions" else "variants"
    source = package_name(name)
    source += "@" + bounded(version, "package version", 128) if version
    value = @notebooks.call("dependency.catalog", {project_id: project[:core_project_id], query: query, source: source}, execution: true)
    if query == "versions":
      return {package_ref: value[:package_ref], versions: value[:versions].map |release|: {version: release[:version], yanked: release[:yanked]}}
    artifacts = value[:artifacts].map |artifact|:
      selection = artifact[:host_selection]
      target = artifact[?:target] or {}
      {variant: artifact[:variant], native_mode: artifact[?:native_mode], size: artifact[?:size],
        target: {os: target[?:os], arch: target[?:arch], min_os: target[?:min_os], compute_backend: target[?:compute_backend]},
        host_selection: {compatible: selection[:compatible], reason: selection[:reason], backend: selection[:backend], bundle: selection[:bundle], allow_native: selection[:allow_native], build_from_source: selection[:build_from_source]}}
    {package_ref: value[:package_ref], version: value[:version], yanked: value[:yanked], recommended_variant: value[:recommended_variant],
      host: {os: value[:host][:os], arch: value[:host][:arch]}, artifacts: artifacts}

  def change(current, id, command, action, name, version, variant, native, build, large):
    project = @catalog.require_project(current, id, capability: :manage)
    raise InvalidInput("Choose Install or Remove.") unless ["install_sputnik", "remove_sputnik"].include?(action)
    raise WebError(403, "native_packages_disabled", "Native package installation/builds are disabled by the server operator.") if not @native and (native or build or large)
    params = {project_id: project[:core_project_id], command_id: command_id(command), action: action, source: package_name(name), version: bounded(version, "package version", 128)}
    if action == "install_sputnik":
      params[:variant] = bounded(variant, "package build") if variant != ""
      params[:allow_native] = native
      params[:build_from_source] = build
      params[:allow_native_large] = large
    accepted = @notebooks.call("dependency.change", params, execution: true)
    {job: {id: accepted[:id], action: accepted[:action], state: accepted[:state], message: ""}}

  def receipt(current, id, command):
    project = @catalog.require_project(current, id)
    response = null
    try:
      response = @notebooks.call("receipt.get", {project_id: project[:core_project_id], command_id: command_id(command)})[:response]
    rescue WebError |error|: raise error unless error.status == 404
    if response and response[?:id] and ["install_sputnik", "remove_sputnik"].include?(response[?:action]):
      return {command: {state: "accepted", job: read(current, id, response[:id])[:job]}}
    {command: {state: "unknown"}}
