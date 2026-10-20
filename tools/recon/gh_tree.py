#!/usr/bin/env python3
"""List the files of public GitHub repositories (to find reference sources).

    python3 tools/recon/gh_tree.py libdyson-wg/opendyson shenxn/libdyson
"""
import json
import sys
import urllib.request

for repo in sys.argv[1:] or sys.exit(__doc__):
    url = "https://api.github.com/repos/%s/git/trees/HEAD?recursive=1" % repo
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "dysonbar-tools"})
        with urllib.request.urlopen(req, timeout=15) as r:
            tree = json.load(r)["tree"]
        print("=== %s ===" % repo)
        for entry in tree:
            print(entry["path"])
    except Exception as e:
        print("=== %s === ERROR %s" % (repo, e))
