package notebook.remote.common

from notebook.core.common import APIError, fail, identifier, decode, canonical, digest, terminal?, project_files, command_at
from notebook.core.client import Client

export APIError, fail, identifier, decode, canonical, digest, terminal?, rpc, project_files, command_at

def rpc(root, method, params: {}):
  try:
    {status: 200, data: Client(root).handle(method, params)}
  rescue APIError |error|:
    {status: error.status, error: error.message}
