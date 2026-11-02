package oauth_transport

from orbit.oauth import Transport

export NotebookOAuthTransport

# OAuth exchanges are infrequent. A request owns its client so a later visit
# cannot reuse a socket that the provider closed while the notebook was idle.
# Exchange an authorization code once; never replay it after a transport error.
class NotebookOAuthTransport:
  def request(method, url, headers: {}, body: null, limit: 65536):
    transport = Transport()
    try:
      transport.request(method, url, headers: headers, body: body, limit: limit)
    ensure:
      transport.close!

  def close!(): null
