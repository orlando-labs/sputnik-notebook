#!/usr/bin/env python3
"""Registry discovery and installation through the real dependency editor."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time


class PackageCatalogFixture:
    def __init__(self, sdk):
        self.temporary = tempfile.TemporaryDirectory(prefix='notebook-package-catalog-')
        self.root = Path(self.temporary.name)
        self.downloads = []
        self.requests = []
        self.archives = {}
        stage = self.root / 'source'
        stage.mkdir()
        (stage / 'main.s').write_text('package test.editor_probe\nexport answer\ndef answer(): 42\n')
        for version in ['0.9.0', '1.0.0', '1.1.0', '2.0.0-rc.1', '3.0.0']:
            (stage / 'sputnik.toml').write_text(
                '[package]\nname="test/editor-probe"\nversion=' + json.dumps(version) +
                '\nroot="test.editor_probe"\n[[modules]]\nname="test.editor_probe"\nsource="main.s"\n')
            archive = self.root / (version + '.sputnikpkg')
            subprocess.run([str(sdk), 'pkg', 'build', str(stage), '--out', str(archive)],
                           check=True, capture_output=True, text=True, timeout=30)
            self.archives[version] = archive.read_bytes()
        fixture = self
        base = '/api/v1/namespaces/test/packages/editor-probe'

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass

            def do_GET(self):
                fixture.requests.append(self.path)
                route = self.path
                if route.startswith('/api/v1/packages/slow/'):
                    time.sleep(0.3)
                for alias in ['editor-probe', 'slow', 'empty']:
                    route = route.replace('/api/v1/packages/' + alias, base, 1)
                version = route.split('/versions/')[-1].split('/')[0]

                def artifact(release_version, variant):
                    body = fixture.archives[release_version]
                    target = dict(os='any', arch='any', compute_backend='none')
                    if variant == 'foreign': target['os'] = 'windows'
                    return dict(package_ref='test/editor-probe', version=release_version, variant=variant, target=target, native_mode='none', bundle='none',
                                quarantined=False, size=len(body), sha256='sha256:' + hashlib.sha256(body).hexdigest(),
                                url=fixture.origin + base + '/versions/' + release_version + '/artifacts/' + variant + '/download')

                def release(release_version):
                    variants = ['foreign'] if release_version == '0.9.0' else ['foreign', 'source']
                    return dict(package_ref='test/editor-probe', version=release_version, yanked=release_version == '3.0.0',
                                artifacts=[artifact(release_version, variant) for variant in variants])

                if '/artifacts/source/download' in route and version in fixture.archives:
                    fixture.downloads.append(version)
                    self.send_response(200)
                    body = fixture.archives[version]
                    self.send_header('x-sputnik-sha256', 'sha256:' + hashlib.sha256(body).hexdigest())
                else:
                    self.send_response(200 if route == base or route == base + '/index' or version in fixture.archives else 404)
                    if route.endswith('/index'):
                        versions = [] if '/packages/empty/' in self.path else [release(v) for v in fixture.archives]
                        data = dict(package_ref='test/editor-probe', revision=1, versions=versions, next_cursor=None)
                    elif '/artifacts/' in route and version in fixture.archives:
                        data = artifact(version, route.split('/artifacts/')[1].split('/')[0])
                    elif version in fixture.archives: data = release(version)
                    elif route == base: data = dict(package_ref='test/editor-probe')
                    else: data = dict(error=dict(code='NOT_FOUND'))
                    body = json.dumps(data).encode()
                    self.send_header('content-type', 'application/json')
                self.send_header('content-length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.origin = 'http://127.0.0.1:' + str(self.server.server_port)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temporary.cleanup()


if __name__ == '__main__':
    fixture = PackageCatalogFixture(Path(sys.argv[1]).resolve())
    try:
        env = dict(os.environ, SPUTNIK_PKG_REGISTRY=fixture.origin, SPUTNIK_TEST_PACKAGE_CATALOG='1')
        env.pop('SPUTNIK_PKG_CREDENTIALS', None)
        subprocess.run([str(Path(sys.argv[2]).resolve()), str(Path(sys.argv[3]).resolve())],
                       env=env, check=True, timeout=180)
        assert fixture.downloads == ['1.0.0'], fixture.downloads
        print('notebook package catalog integration passed')
    finally:
        fixture.close()
