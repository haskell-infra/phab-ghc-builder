import sys, os
import subprocess

sys.path.insert(1,'third_party/flask-0.10.1')
sys.path.insert(1,'third_party/werkzeug-0.8.3')
sys.path.insert(1,'third_party/Jinja2-2.7.3')
sys.path.insert(1,'third_party/MarkupSafe-0.23')
sys.path.insert(1,'third_party/itsdangerous-0.24')
from flask import Flask

app = Flask(__name__)
app.debug = True

@app.route("/build/<int:buildid>/<int:diff>/<int:revision>/<phid>")
def hello(buildid, diff, revision, phid):
    localdir = os.path.dirname(os.path.realpath(__file__))
    buildscript = localdir+"/builder.sh"
    subprocess.Popen(["bash", buildscript,
                      str(buildid), str(diff), str(revision), phid])
    return 'OK'

if __name__ == "__main__":
    app.run()
