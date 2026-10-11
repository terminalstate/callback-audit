"""Install the packages of a composer.lock into vendor/ from their GitHub sources.

For machines that cannot reach Packagist (or GitHub zipball downloads) but can reach github.com over git/https.
Each locked package is shallow-fetched at its locked commit; vendor/composer/installed.json is then written so that
`composer dump-autoload` can build the autoloader. Usage: python3 fetch_vendor.py <project dir>
"""

import concurrent.futures
import json
import os
import subprocess
import sys


def source_of(package):
    src = package.get("source") or {}
    if src.get("url"):
        return src["url"], src["reference"]
    dist = package["dist"]  # dist-only packages (e.g. phpstan/phpstan): rebuild the git URL from the zipball URL
    owner_repo = "/".join(dist["url"].split("/repos/")[1].split("/")[:2])
    return f"https://github.com/{owner_repo}.git", dist["reference"]


def fetch(vendor, package):
    dest = os.path.join(vendor, package["name"])
    if os.path.exists(os.path.join(dest, ".done")):
        return package["name"], "cached"
    url, ref = source_of(package)
    os.makedirs(dest, exist_ok=True)
    for cmd in (["git", "init", "-q"], ["git", "fetch", "-q", "--depth", "1", url, ref], ["git", "checkout", "-q", "FETCH_HEAD"]):
        result = subprocess.run(cmd, cwd=dest, capture_output=True, text=True, timeout=900)
        if result.returncode:
            return package["name"], f"FAIL {' '.join(cmd[:3])}: {result.stderr.strip()[:200]}"
    subprocess.run(["rm", "-rf", ".git"], cwd=dest, check=True)
    open(os.path.join(dest, ".done"), "w").close()
    return package["name"], "ok"


def main(root):
    with open(os.path.join(root, "composer.lock")) as f:
        lock = json.load(f)
    packages = lock["packages"] + lock.get("packages-dev", [])
    vendor = os.path.join(root, "vendor")
    with concurrent.futures.ThreadPoolExecutor(12) as pool:
        results = list(pool.map(lambda p: fetch(vendor, p), packages))
    failed = [r for r in results if r[1] not in ("ok", "cached")]
    print(f"{len(results)} packages, {len(failed)} failed")
    for name, status in failed:
        print(f"  {name}: {status}")
    installed = [dict(p, **{"install-path": "../" + p["name"]}) for p in packages]
    dev_names = [p["name"] for p in lock.get("packages-dev", [])]
    os.makedirs(os.path.join(vendor, "composer"), exist_ok=True)
    with open(os.path.join(vendor, "composer", "installed.json"), "w") as f:
        json.dump({"packages": installed, "dev": True, "dev-package-names": dev_names}, f, indent=1)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
