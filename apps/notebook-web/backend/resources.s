package resources

export Resources

# Browser DTOs never expose Core identities, other projects' usage or disk paths.
# The Core remains authoritative; the web editor saves only authored overrides.
class Resources:
  def init(@catalog, @notebooks)

  def limits(values):
    result = {}
    ["run_count", "run_age_seconds", "project_bytes", "max_run_bytes", "minimum_free_bytes", "revision_count", "run_seconds", "total_run_seconds"].each |key|:
      value = values[?key]
      result[key] = if value == null then null else value.to_str
    result

  def summary(project, aggregate_user: false):
    policy = @notebooks.call("policy.get", {project_id: project}, execution: true)
    present(policy, aggregate_user: aggregate_user)

  def present(policy, aggregate_user: false):
    remaining = null
    ip_remaining = null
    policy[:scopes].each |scope|:
      seconds = scope[:limits][?:total_run_seconds]
      if seconds:
        value = seconds * 1000 - scope[:spent_ms]
        value = 0 if value < 0
        remaining = value if remaining == null or value < remaining
        ip_remaining = value if scope[:kind] == "public_ip"
    user = policy[:scopes].find: $it[:kind] == "user"
    charged = if aggregate_user and user then user[:spent_ms] else policy[:spent_ms]
    result = {effective: limits(policy[:effective]), defaults: limits(policy[:defaults] or {}),
      temporary: policy[:temporary], allow_book_policy_overrides: policy[:allow_book_policy_overrides],
      spent_ms: charged.to_str, remaining_ms: if remaining == null then null else remaining.to_str}
    result[:ip_remaining_ms] = ip_remaining.to_str if ip_remaining != null
    result

  def read(current, id):
    project = @catalog.require_project(current, id)
    result = summary(project[:core_project_id], aggregate_user: @catalog.guest?(current))
    storage = @notebooks.call("storage.status", {project_id: project[:core_project_id]}, execution: true)
    result[:storage] = {project_bytes: storage[:project_bytes].to_str, retained_runs: storage[:retained_runs].to_str, active_runs: storage[:active_runs].to_str}
    {resources: result}
