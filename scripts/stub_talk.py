#!/usr/bin/env python3
"""A stand-in for the talk page, for the simulator job only.

The real page lives in a private repo and needs the tailnet. This serves a
static look-alike at /talk/stub/ plus /health so the shell has something to
load in CI. It contains nothing real.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ap = argparse.ArgumentParser(); ap.add_argument("--port", type=int, default=8765)
args = ap.parse_args()
PAGE = b"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<style>html,body{margin:0;height:100%;background:#0b0b0d;color:#e8e6e1;font:17px/1.45 -apple-system,system-ui,sans-serif}
body{padding:env(safe-area-inset-top) 0 env(safe-area-inset-bottom);display:flex;flex-direction:column}
header{display:flex;align-items:center;gap:10px;padding:14px 18px;color:#a9a6a0}
#dot{width:12px;height:12px;border-radius:50%;background:#5fd98a}
main{flex:1;padding:12px 18px}.lbl{font-size:13px;letter-spacing:.08em;color:#8b8880;margin-top:16px}
.you{color:#e8955c}footer{display:flex;gap:10px;padding:14px 18px}
footer button{flex:1;background:#1a1c22;color:#e8e6e1;border:0;border-radius:16px;padding:18px;font-size:19px}
.card{margin:6px 0 10px;background:#15171c;border-left:3px solid #e8955c;border-radius:14px;padding:16px}
.card b{display:block;margin-bottom:6px}.card button{border:0;border-radius:12px;padding:14px;font-size:18px;width:48%}
</style></head><body><header><div id="dot"></div><div>listening</div></header><main>
<div class="card"><b>Add 2 tins of tomatoes to the pantry</b><small>Pantry: +2 chopped tomatoes</small><br><br>
<button style="background:#5fd98a">Approve</button> <button style="background:#2a2d35;color:#fff">Deny</button></div>
<div class="lbl">YOU</div><div class="you">what is on today</div>
<div class="lbl">MURRAY</div><div>Four things today. The big one is the paper at ten.</div>
<p style="color:#5a5852;font-size:13px;margin-top:40px">simulator stub &mdash; not the real page</p></main>
<footer><button>Mute</button><button>Hold to talk</button><button>End</button></footer></body></html>"""


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_GET(self):
        if self.path == "/talk/stub/health":
            body, ctype = b'{"ok": true, "stub": true}', "application/json"
        elif self.path in ("/talk/stub/", "/talk/stub"):
            body, ctype = PAGE, "text/html; charset=utf-8"
        else:
            self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)


print("stub talk page: http://127.0.0.1:%d/talk/stub/" % args.port, flush=True)
ThreadingHTTPServer(("127.0.0.1", args.port), H).serve_forever()
