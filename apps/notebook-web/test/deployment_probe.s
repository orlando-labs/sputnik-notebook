package deployment_probe

from net.http import Client

export main

def check(value, message):
  raise ValueError("deployment acceptance: " + message) unless value

class Visitor:
  def init(@origin, @cookies, @connect_origin): @client = Client(timeout: 10.0, redirects: :off)

  def request(path, method: "GET", data: null, status: 200):
    headers = {accept: "application/json", origin: @origin, connection: "close"}
    if @connect_origin:
      authority = @origin.slice(@origin.index("://") + 3...@origin.length)
      headers.merge!({host: authority, "x-forwarded-host": authority, "x-forwarded-proto": "https", "x-forwarded-for": "127.0.0.1"})
    headers[:cookie] = (@cookies.map |key, value|: key + "=" + value).join("; ")
    headers["x-csrf-token"] = Url.percent_decode(@cookies["orbit-csrf"]) if @cookies[?"orbit-csrf"]
    headers["content-type"] = "application/json" if data != null
    body = if data != null then Json.generate(data) else null
    url = (@connect_origin or @origin) + path
    response = if method == "GET": @client.get(url, headers: headers)
    elif method == "POST": @client.post(url, headers: headers, body: body)
    elif method == "PUT": @client.put(url, headers: headers, body: body)
    elif method == "DELETE": @client.delete(url, headers: headers)
    else: raise ArgumentError("unsupported probe method")
    try:
      response.headers.all("set-cookie").each |entry|:
        pair = entry.split(";")[0]
        equal = pair.index("=")
        @cookies[pair.slice(0...equal)] = pair.slice(equal + 1...pair.length) if equal
      text = response.body_text(limit: 1048576)
      if response.status != status:
        raise ValueError("deployment acceptance: " + method + " " + path.split("/")[1] + " returned " + response.status.to_str)
      if text.present? then Json.parse(text, duplicate_keys: :reject) else null
    ensure:
      response.close!

  def open():
    request("/api/public/sessions", method: "POST", data: {template_id: "starter", command_id: "deploy_" + SecureRandom.hex(16)})

  def close!(): @client.close!

def main():
  parser = ArgParser()
  parser.arg("--origin", required: true)
  parser.arg("--connect-origin")
  parser.arg("--state", required: true)
  parser.arg("--phase", choices: ["begin", "verify"], required: true)
  parser.arg("--report", required: true)
  parser.flag("--allow-http-loopback")
  args = parser.parse_or_raise
  origin = args[:origin]
  check(origin.starts_with?("https://") or (args[:allow_http_loopback] and origin.starts_with?("http://127.0.0.1:")), "use verified HTTPS or an explicit loopback fixture")
  check(args[:allow_http_loopback] and args[:connect_origin].starts_with?("http://127.0.0.1:"), "proxy fixture override must be explicit loopback") if args[:connect_origin]
  before = if args[:phase] == "verify" then Json.parse(fs.read_text(args[:state], limit: 65536)) else {cookies: {}, origin: origin}
  check(before[:origin] == origin, "visitor state belongs to another origin")
  visitor = Visitor(origin, before[:cookies], args[:connect_origin])
  try:
    snapshot = visitor.request("/api/session")
    check(snapshot[:account] == null and snapshot[:sign_in_available] == false, "public-only entry must not create an account")
    check(visitor.request("/health/ready")[:ready] == true, "Core readiness")
    visitor.request("/api/projects", status: 401)
    copy = visitor.open()
    lease = "/api/public/sessions/" + copy[:session_id]
    base = "/api/projects/guest_" + copy[:session_id]
    resources = visitor.request(base + "/execution")[:resources]
    if args[:phase] == "begin":
      ip_before = resources[:ip_remaining_ms].to_int
      before[:ip_day] = Time.now.unix_milliseconds // 86400000
      notebook = visitor.request(base + "/notebook")[:notebook]
      document = Json.parse(notebook[:document])
      check(document[:sheets].count > 1 and document[:boards].present?, "public starter is a full notebook with a board")
      document[:sheets][0][:cells][0][:source] = "import task\ntask.sleep(300)\n42\n"
      saved = visitor.request(base + "/notebook", method: "PUT", data: {command_id: "save_" + SecureRandom.hex(16), base_revision: notebook[:revision], document: Json.generate(document)})[:notebook]
      run = visitor.request(base + "/execution/runs", method: "POST", data: {command_id: "run_" + SecureRandom.hex(16), revision: saved[:revision], sheet_id: "main", cell_id: "1", action: "run_all"})[:run]
      final = null
      200.times:
        final = visitor.request(base + "/execution/runs/" + run[:id])[:run]
        break if ["succeeded", "failed", "force-stopped", "interrupted", "cancelled"].include?(final[:state])
        visitor.request(lease + "/lease", method: "POST", data: {})
        task.sleep(0.1)
      check(final[:state] == "succeeded" and final[:cells][0][:result] == "42", "explicit real-worker result")
      resources = visitor.request(base + "/resources")[:resources]
      check(resources[:spent_ms].to_int > 0 and resources[:remaining_ms].to_int < 60000, "real execution is charged")
      before[:charged_ms] = resources[:spent_ms]
      before[:ip_remaining_ms] = resources[:ip_remaining_ms]
      if before[:ip_day] == Time.now.unix_milliseconds // 86400000:
        check(ip_before - resources[:ip_remaining_ms].to_int >= resources[:spent_ms].to_int, "real execution is charged to the shared IP")
      visitor.request(lease, method: "DELETE")
      fs.File.open(args[:state], :write, create: true, exclusive: true, permissions: 384) |file|:
        file.write_all!(Json.generate(before).bytes)
        file.sync!()
    else:
      resources = copy[:resources]
      check(resources[:spent_ms].to_int >= before[:charged_ms].to_int and resources[:remaining_ms].to_int < 60000, "restart/restore must retain anonymous charged time")
      if before[?:ip_day] == Time.now.unix_milliseconds // 86400000:
        check(resources[:ip_remaining_ms].to_int <= before[:ip_remaining_ms].to_int, "restart/restore must retain same-day IP usage")
      visitor.request(lease, method: "DELETE")
    check(resources[:effective][:total_run_seconds] == "60" and resources[:effective][:project_bytes] == "67108864", "public time/storage ceilings")
    fs.write_text(args[:report], Json.generate({phase: args[:phase], origin: origin, ready: true, account_created: false,
      charged_before_ms: before[:charged_ms], charged_after_ms: resources[:spent_ms], remaining_ms: resources[:remaining_ms],
      quota_seconds: resources[:effective][:total_run_seconds], storage_bytes: resources[:effective][:project_bytes], ip_remaining_ms: resources[:ip_remaining_ms]}))
    print "PASS deployed public session " + args[:phase] + ": Core ready, no account, real execution and preserved anonymous quota"
  ensure:
    visitor.close!()
