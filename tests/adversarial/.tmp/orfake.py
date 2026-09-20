import http.server, json, sys, threading, time
MODE=sys.argv[1]; N=[0]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length',0))); N[0]+=1
        if MODE=='502html':
            b=b'<html><body>\x1b[31m502 Bad Gateway \xe2\x80\x94 \x9b2J\xc2\x9b\xe2\x80\xae retry\r</body></html>'; self.send_response(502)
            self.send_header('Content-Type','text/html'); self.send_header('Content-Length',str(len(b)))
            self.end_headers(); self.wfile.write(b); return
        if MODE=='429' and N[0]<3: code,body=429,{"error":{"message":"rate limited"}}
        elif MODE=='401': code,body=401,{"error":{"message":"bad key"}}
        else: code,body=200,{"choices":[{"message":{"content":"SEVERITY: WARNING\nCONFIDENCE: high\nFILE: x\nISSUE: y\nATTACK VECTOR: z\nSUGGESTED FIX: w\n"+("x"*1200)}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
        b=json.dumps(body).encode(); self.send_response(code)
        self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def log_message(self,*a): pass
s=http.server.HTTPServer(('127.0.0.1',0),H); print(s.server_port, flush=True)
threading.Thread(target=s.serve_forever,daemon=True).start(); time.sleep(90)
