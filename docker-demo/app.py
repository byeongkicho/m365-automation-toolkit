"""
Minimal Flask dashboard that reads M365 security audit JSON logs
and displays a summary. Demonstrates containerized web app for DevOps portfolio.
"""

import json
import os
import glob
from flask import Flask, render_template

app = Flask(__name__)
LOG_DIR = os.environ.get("LOG_DIR", "/app/logs")


def load_latest_audit():
    pattern = os.path.join(LOG_DIR, "security-audit-*.json")
    files = sorted(glob.glob(pattern), reverse=True)
    if not files:
        return None
    with open(files[0]) as f:
        return json.load(f)


@app.route("/")
def dashboard():
    audit = load_latest_audit()
    return render_template("dashboard.html", audit=audit)


@app.route("/health")
def health():
    return {"status": "ok"}, 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
