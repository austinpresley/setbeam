# Local QA only: relay an isolated sample viewer to a selected LAN address for insecure-origin Copy checks.
# Usage: python3 scripts/check-chat-lan-relay.py session.json LAN_IP output-session.json
import http.server,http.client,json,os,pathlib,urllib.parse,sys
source=json.loads(pathlib.Path(sys.argv[1]).read_text())
u=urllib.parse.urlsplit(source['viewerURL'])
class Proxy(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def do_GET(self): self.forward()
    def do_POST(self): self.forward()
    def forward(self):
        if not self.path.startswith(u.path):self.send_error(404);return
        connection=http.client.HTTPConnection('127.0.0.1',u.port,timeout=30)
        try:
            body=self.rfile.read(int(self.headers.get('Content-Length','0')))
            headers={k:v for k,v in self.headers.items() if k.lower() not in ['connection','accept-encoding']}
            connection.request(self.command,self.path,body=body or None,headers=headers)
            response=connection.getresponse();self.send_response(response.status)
            for name,value in response.getheaders():
                if name.lower() not in ['transfer-encoding','connection']:self.send_header(name,value)
            self.send_header('Connection','close');self.end_headers()
            while chunk:=response.read1(65536):self.wfile.write(chunk);self.wfile.flush()
        except (BrokenPipeError,ConnectionResetError,TimeoutError): pass
        finally: connection.close()
    def log_message(self,*args):pass
server=http.server.ThreadingHTTPServer((sys.argv[2],0),Proxy);server.daemon_threads=True
out=pathlib.Path(sys.argv[3])
out.write_text(json.dumps({'viewerURL':f'http://{sys.argv[2]}:{server.server_port}{u.path}','pid':os.getpid()}));out.chmod(0o600)
server.serve_forever()
