"""The iPhone shell. What is worth pinning:

  * the repo never carries the talk URL — it holds a secret — only the
    template placeholder; configure.sh fills it from the environment and
    refuses to write a config that loads nothing,
  * the iOS project declares what the page needs (microphone purpose string,
    audio background mode) and nothing looser than local networking,
  * the workflow never echoes a secret and only signs when the secrets exist,
  * the mock server serves the REAL page and its health endpoint, so the
    preview is the page and not a drawing of it.
"""
import json
import os
import pathlib
import plistlib
import re
import socket
import subprocess
import sys
import time
import urllib.request

REPO = pathlib.Path(__file__).resolve().parent.parent
APP = REPO
FAILURES = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name
          + (" — %s" % (detail,) if not ok and detail else ""))
    if not ok:
        FAILURES.append(name)


# ---- 1. the secret stays out of git ---------------------------------------
tmpl = json.loads((APP / "capacitor.config.template.json").read_text())
check("template carries the placeholder, not a URL",
      tmpl["server"]["url"] == "__TALK_URL__")
check("no navigation away from the page", tmpl["server"]["allowNavigation"] == [])
check("the offline fallback is wired", tmpl["server"].get("errorPath") == "index.html"
      and (APP / "www" / "index.html").exists())
tracked = subprocess.run(["git", "ls-files"], cwd=REPO,
                         capture_output=True, text=True).stdout.split()
check("capacitor.config.json is never tracked",
      not any(p.endswith("capacitor.config.json") for p in tracked), tracked[:3])
gi = (APP / ".gitignore").read_text()
check(".gitignore covers both generated configs",
      "capacitor.config.json" in gi and "ios/App/App/capacitor.config.json" in gi)

env = dict(os.environ, TALK_URL="")
r = subprocess.run(["bash", "scripts/configure.sh"], cwd=APP, env=env,
                   capture_output=True, text=True)
check("configure refuses an empty TALK_URL", r.returncode == 2 and "refusing" in r.stderr)
r = subprocess.run(["bash", "scripts/configure.sh"], cwd=APP,
                   env=dict(os.environ, TALK_URL="ftp://nope/"),
                   capture_output=True, text=True)
check("configure refuses a non-https URL", r.returncode == 2)
url = "https://murray.example.ts.net/talk/s3cr3t-value/"
r = subprocess.run(["bash", "scripts/configure.sh"], cwd=APP,
                   env=dict(os.environ, TALK_URL=url), capture_output=True, text=True)
out = json.loads((APP / "capacitor.config.json").read_text())
check("configure writes the URL into the config", r.returncode == 0
      and out["server"]["url"] == url, r.stderr)
check("and prints only the host, never the secret",
      "s3cr3t" not in r.stdout + r.stderr and "murray.example.ts.net" in r.stdout)
check("the offline page's Try again points at the real URL after configure",
      url in (APP / "www/index.html").read_text())
subprocess.run(["git", "checkout", "--", "www/index.html"], cwd=APP)
(APP / "capacitor.config.json").unlink()

# ---- 2. the iOS project says what it needs ---------------------------------
plist = plistlib.loads((APP / "ios/App/App/Info.plist").read_bytes())
check("microphone purpose string present",
      "listen" in plist.get("NSMicrophoneUsageDescription", "").lower())
check("audio background mode declared", plist.get("UIBackgroundModes") == ["audio"])
ats = plist.get("NSAppTransportSecurity", {})
check("ATS: local networking only, no arbitrary cleartext",
      ats.get("NSAllowsLocalNetworking") is True
      and not ats.get("NSAllowsArbitraryLoads"), ats)
check("display name is Murray", plist.get("CFBundleDisplayName") == "Murray")
pkg = json.loads((APP / "package.json").read_text())
check("no sharp-based asset tool (needs a native build on install)",
      "@capacitor/assets" not in json.dumps(pkg))
icon = APP / "ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png"
check("app icon rendered", icon.exists() and icon.stat().st_size > 1000)

# ---- 3. the workflow -------------------------------------------------------
wf = (REPO / ".github/workflows/ios-app.yml").read_text()
check("workflow signs only behind the secrets gate",
      "needs.gate.outputs.signed == 'true'" in wf)
check("workflow never echoes TALK_URL",
      not re.search(r"echo[^\n]*TALK_URL", wf))
check("workflow shreds the key even on failure",
      "if: always()" in wf and "rm -f ~/.appstoreconnect/private_keys" in wf)
check("simulator build is unsigned", "CODE_SIGNING_ALLOWED=NO" in wf)
check("ExportOptions is app-store-connect, automatic",
      "app-store-connect" in (APP / "ExportOptions.plist").read_text())

# ---- 4. the mock serves the real page ---------------------------------------
s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
proc = subprocess.Popen([sys.executable, "scripts/stub_talk.py", "--port", str(port)],
                        cwd=APP, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
base = "http://127.0.0.1:%d/talk/stub" % port
try:
    body = ""
    for _ in range(40):
        try:
            body = urllib.request.urlopen(base + "/health", timeout=2).read().decode()
            break
        except Exception:
            time.sleep(0.25)
    health = json.loads(body or "{}")
    check("stub health answers",
          health.get("ok") and health.get("stub"), body)
    page = urllib.request.urlopen(base + "/", timeout=5).read().decode()
    check("stub page renders the shell", "Approve" in page)
    wrong = urllib.request.Request(base.replace("/stub", "/wrong") + "/")
    try:
        urllib.request.urlopen(wrong, timeout=5); code = 200
    except urllib.error.HTTPError as e:
        code = e.code
    check("an unknown path is a 404 on the stub", code == 404, code)
finally:
    proc.terminate(); proc.wait(timeout=5)

print("\n%d failures" % len(FAILURES))
sys.exit(1 if FAILURES else 0)
