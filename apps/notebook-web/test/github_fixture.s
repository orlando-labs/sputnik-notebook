package github_fixture

import orbit
import orbit.html as html_helpers
import orbit.html as markup
from sync import Mutex

export main

class State:
  attr callback
  def init(@callback):
    @mutex = Mutex.new
    @codes = {}
    @tokens = {}

  def issue(challenge, user):
    code = SecureRandom.base64url(32)
    @mutex.synchronize:
      @codes[code] = {challenge: challenge, user: user}
    code

  def exchange(form):
    code = form[?:code]
    return null unless Str === code
    expected = @mutex.synchronize:
      result = @codes[?code]
      @codes.delete!(code) if result
      result
    return null unless expected and Str === form[?:code_verifier]
    actual = Base64Url.encode(Digest.sha256(form[:code_verifier].bytes))
    return null unless expected[:challenge] == actual and form[?:redirect_uri] == @callback
    return null unless form[?:client_id] == "fixture-client" and form[?:client_secret] == "fixture-secret" and form[?:grant_type] == "authorization_code"
    token = SecureRandom.base64url(32)
    @mutex.synchronize:
      @tokens[token] = expected[:user]
    token

  def profile(header):
    return false unless Str === header and header.starts_with?("Bearer ")
    token = header.slice(7...header.length)
    @mutex.synchronize: @tokens[?token]

class Provider < orbit.Controller:
  def authorize():
    query = request.query_params
    state = service(:fixture)
    valid = query[?:client_id] == "fixture-client" and query[?:redirect_uri] == state.callback
    valid = valid and query[?:response_type] == "code" and query[?:code_challenge_method] == "S256"
    valid = valid and Str === query[?:state] and Str === query[?:code_challenge]
    return render(json: {error: "invalid_request"}, status: 400) unless valid
    render(html: markup.html"""
      <!doctype html>
      <html><head><title>GitHub fixture</title></head><body>
        <h1>Local GitHub test provider</h1>
        <p>This is an offline OAuth fixture, not github.com.</p>
        <form method="post" action="/approve">
          <input type="hidden" name="state" value="#{query[:state]}">
          <input type="hidden" name="code_challenge" value="#{query[:code_challenge]}">
          <button name="decision" value="alice">Sign in as Alice</button>
          <button name="decision" value="bob">Sign in as Bob</button>
          <button name="decision" value="deny">Cancel authorization</button>
        </form>
      </body></html>
      """)

  def approve():
    form = Url.parse_query(request.body_text)
    target = {state: form[?:state]}
    if ["alice", "bob"].include?(form[?:decision]) and Str === form[?:code_challenge]:
      target[:code] = service(:fixture).issue(form[:code_challenge], form[:decision])
    else:
      target[:error] = "access_denied"
    redirect(service(:fixture).callback + "?" + Url.build_query(target), status: 303, external: true)

  def token():
    value = service(:fixture).exchange(Url.parse_query(request.body_text))
    return render(json: {error: "invalid_grant"}, status: 400) unless value
    render(json: {access_token: value, token_type: "bearer", scope: "read:user"})

  def profile():
    user = service(:fixture).profile(request.header("authorization"))
    return render(json: {error: "unauthorized"}, status: 401) unless user
    render(json: if user == "alice" then {id: 9007199254740995, login: "alice", name: "Alice"} else {id: 2, login: "bob", name: "Bob"})

routes = orbit.routes:
  get "/login/oauth/authorize", to: &Provider#authorize
  post "/approve", to: &Provider#approve
  post "/login/oauth/access_token", to: &Provider#token
  get "/user", to: &Provider#profile

def main():
  parser = ArgParser()
  parser.arg("--port", type: Int, required: true)
  parser.arg("--callback-origin", required: true)
  args = parser.parse_or_raise
  origin = orbit.Origin(args[:callback_origin])
  security = orbit.SecurityPolicy(content_security_policy: orbit.ContentSecurityPolicy(
    form_action: [:self, origin.to_str]))
  orbit.App(routes: routes, security: security,
    services: {fixture: State(origin.to_str + "/auth/github/callback")}).run(port: args[:port])
