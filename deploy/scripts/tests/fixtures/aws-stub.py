# Test stub for configure.sh --aws-marketplace: answers as EC2 instance
# metadata (IMDSv2) and as the licence server's /v1/aws/activate.
#   python3 aws-stub.py <port> <dir>   (dir: document.json, writes request.json)
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
PORT, DIR = int(sys.argv[1]), sys.argv[2]
DOC = open(os.path.join(DIR, 'document.json')).read()
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body, ctype='text/plain'):
        b = body.encode(); self.send_response(code); self.send_header('Content-Type', ctype); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_PUT(self):
        self.send(200, 'tok123') if self.path == '/latest/api/token' else self.send(404, '')
    def do_GET(self):
        if self.headers.get('X-aws-ec2-metadata-token') != 'tok123': return self.send(401, '')
        if self.path.endswith('/document'): return self.send(200, DOC)
        if self.path.endswith('/signature'): return self.send(200, 'c2ln\nbmF0dXJl')
        if self.path.endswith('/rsa2048'): return self.send(200, 'MIAGCSqG\nSIb3DQ==')
        self.send(404, '')
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', 0))).decode()
        req = json.loads(raw)
        open(os.path.join(DIR, 'request.json'), 'w').write(raw)
        if req.get('document') != DOC: return self.send(400, json.dumps({'ok': False, 'error': 'document altered'}), 'application/json')
        if 'paid' not in DOC: return self.send(403, json.dumps({'ok': False, 'error': 'this instance does not run the paid product', 'code': 'NOT_PAID_PRODUCT'}), 'application/json')
        self.send(201, json.dumps({'ok': True, 'lid': 'AWS-i-0abc', 'tier': 'enterprise', 'domain': req['domain'], 'key': 'ETHORA1.eyJsaWQiOiJBV1MifQ.c2ln', 'expiresAt': '2026-12-25T00:00:00.000Z'}), 'application/json')
HTTPServer(('127.0.0.1', PORT), H).serve_forever()
