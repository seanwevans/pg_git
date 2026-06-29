-- Path: /test/sql/https_fetch_test.sql
-- Tests for pggit.http_fetch.
--
-- These exercise the success path, the read-timeout path and TLS certificate
-- verification. To keep the suite deterministic in CI they run against local
-- servers started inside the backend rather than third-party endpoints, so the
-- result never depends on the availability of an external service.

BEGIN;

SELECT plan(3);

-- Setup test repository
SELECT pggit.init_repository('test_repo', '/test/path') AS repo_id \gset
SELECT set_config('vars.repo_id', :'repo_id', false);

-- Start local HTTP and HTTPS test servers in daemon threads within this
-- backend. http_fetch runs in the same backend, so it can reach them over the
-- loopback interface. OS-assigned ports are stashed in GUCs for the assertions.
DO $py$
import http.server
import os
import socket
import ssl
import subprocess
import tempfile
import threading
import time


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # A slow endpoint lets us trip http_fetch's built-in 10s read timeout.
        if self.path.startswith('/slow'):
            time.sleep(12)
        body = b'pg_git local server OK'
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):  # keep the test output quiet
        pass


httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 0), _Handler)
http_port = httpd.server_address[1]
threading.Thread(target=httpd.serve_forever, daemon=True).start()

# A self-signed certificate for the verification-failure case. Generated at
# runtime (via the openssl CLI) so no private key is committed to the repo.
certdir = tempfile.mkdtemp(prefix='pggit_tls_')
certfile = os.path.join(certdir, 'cert.pem')
keyfile = os.path.join(certdir, 'key.pem')
subprocess.run(
    ['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
     '-keyout', keyfile, '-out', certfile,
     '-days', '3650', '-subj', '/CN=pggit-test'],
    check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

tls_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls_ctx.load_cert_chain(certfile, keyfile)

tls_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
tls_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
tls_sock.bind(('127.0.0.1', 0))
tls_sock.listen(5)
tls_port = tls_sock.getsockname()[1]


def _serve_tls():
    while True:
        try:
            conn, _ = tls_sock.accept()
        except OSError:
            return
        try:
            # The client rejects the self-signed cert during the handshake;
            # we just need to present it.
            tls_ctx.wrap_socket(conn, server_side=True)
        except (ssl.SSLError, OSError):
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass


threading.Thread(target=_serve_tls, daemon=True).start()

plpy.execute("SELECT set_config('vars.http_port', '%d', false)" % http_port)
plpy.execute("SELECT set_config('vars.tls_port', '%d', false)" % tls_port)
$py$ LANGUAGE plpython3u;

-- Successful fetch should return the served body.
SELECT alike(
    encode(
        pggit.http_fetch(
            current_setting('vars.repo_id')::int,
            'http://127.0.0.1:' || current_setting('vars.http_port') || '/'),
        'escape'),
    '%local server OK%',
    'Successful fetch returns expected content'
);

-- Timeout scenario: the slow endpoint exceeds http_fetch's read timeout.
SELECT throws_like(
    format(
        $$SELECT pggit.http_fetch(%s, %L)$$,
        current_setting('vars.repo_id'),
        'http://127.0.0.1:' || current_setting('vars.http_port') || '/slow'),
    '%timed out%',
    'Timeout raises error'
);

-- Certificate verification error scenario: the server presents a self-signed cert.
SELECT throws_like(
    format(
        $$SELECT pggit.http_fetch(%s, %L)$$,
        current_setting('vars.repo_id'),
        'https://127.0.0.1:' || current_setting('vars.tls_port') || '/'),
    '%certificate verify failed%',
    'Certificate error raises exception'
);

SELECT * FROM finish();
ROLLBACK;
