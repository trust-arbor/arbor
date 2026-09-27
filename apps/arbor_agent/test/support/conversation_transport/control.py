"""Control only the disposable loopback conversation transport fixture."""
import argparse
import json
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument("action", choices=["revoke", "finish"])
args = parser.parse_args()
with open("/private/tmp/convergence-transport.json", encoding="utf-8") as fixture:
    info = json.load(fixture)
with urllib.request.urlopen(info[args.action], timeout=5) as response:
    print(response.read().decode())
