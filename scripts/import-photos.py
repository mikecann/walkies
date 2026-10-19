# Adds photos to secrets, from Wikimedia Commons only.
# Usage: python3 -I scripts/import-photos.py <picks.json>...
#
# Each picks file holds [{"id": "<secret id>", "photos": [{"file": "File:Name.jpg", "caption": "..."}]}].
# Every file's licence is checked on Commons itself, and anything that isn't CC0, public
# domain, CC BY or CC BY-SA is dropped, whatever the picks say. Kept photos are downloaded at
# 1100 px wide, compressed, added to the asset catalog as photo-<id>-<n>, and listed on the
# secret in the lore JSON with their caption and credit.
import html, json, os, re, subprocess, sys, time, urllib.parse, urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LORE = [os.path.join(REPO, "Walkies/Lore", f) for f in ("geographe.json", "busselton-area.json")]
CATALOG = os.path.join(REPO, "Walkies/Assets.xcassets/Photos")
UA = {"User-Agent": "Walkies/0.1 (personal iOS app; mike@cannstudios.com)"}
API = "https://commons.wikimedia.org/w/api.php"


def free(licence):
    licence = (licence or "").lower()
    return licence in ("cc0", "pd") or licence.startswith(("cc-by", "pd-", "cc-zero", "public domain"))


def info(titles):
    """Licence, credit and a 1100 px thumbnail for up to 50 Commons files."""
    query = urllib.parse.urlencode({
        "action": "query", "format": "json", "prop": "imageinfo", "titles": "|".join(titles),
        "iiprop": "url|extmetadata|mime", "iiurlwidth": 1100,
    })
    with urllib.request.urlopen(urllib.request.Request(f"{API}?{query}", headers=UA), timeout=60) as r:
        pages = json.load(r)["query"]["pages"].values()
    out = {}
    for page in pages:
        if "imageinfo" not in page:
            continue
        ii = page["imageinfo"][0]
        meta = ii.get("extmetadata", {})
        get = lambda k: html.unescape(re.sub(r"<[^>]+>", "", meta.get(k, {}).get("value", ""))).strip()
        out[page["title"]] = {
            "thumb": ii.get("thumburl") or ii.get("url"),
            "page": ii.get("descriptionurl"),
            "mime": ii.get("mime", ""),
            "licence": meta.get("License", {}).get("value", ""),
            "licenceName": get("LicenseShortName"),
            "artist": re.sub(r"\s+", " ", get("Artist"))[:80],
        }
    return out


picks = []
for path in sys.argv[1:]:
    text = open(path).read()
    block = re.findall(r"```json\s*(.*?)```", text, re.S)
    picks += json.loads(block[0] if block else text)

wanted = sorted({p["file"].replace("_", " ") for pick in picks for p in pick["photos"]})
found = {}
for i in range(0, len(wanted), 50):
    found.update(info(wanted[i:i + 50]))
    time.sleep(1)

os.makedirs(CATALOG, exist_ok=True)
with open(os.path.join(CATALOG, "Contents.json"), "w") as f:
    json.dump({"info": {"author": "xcode", "version": 1}}, f)

photos, dropped = {}, []
for pick in picks:
    kept = []
    for p in pick["photos"][:2]:
        meta = found.get(p["file"].replace("_", " "))
        if not meta:
            dropped.append(f"{pick['id']}: {p['file']} (not on Commons)")
            continue
        if not free(meta["licence"]):
            dropped.append(f"{pick['id']}: {p['file']} (licence {meta['licence'] or meta['licenceName'] or 'unknown'})")
            continue
        if not meta["mime"].startswith("image/") or meta["mime"] == "image/svg+xml":
            dropped.append(f"{pick['id']}: {p['file']} ({meta['mime']})")
            continue
        name = f"photo-{pick['id']}-{len(kept) + 1}"
        folder = os.path.join(CATALOG, f"{name}.imageset")
        os.makedirs(folder, exist_ok=True)
        raw = os.path.join(folder, "raw")
        with urllib.request.urlopen(urllib.request.Request(meta["thumb"], headers=UA), timeout=60) as r, open(raw, "wb") as f:
            f.write(r.read())
        subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "72", "-Z", "1100", raw, "--out", os.path.join(folder, "photo.jpg")],
                       check=True, capture_output=True)
        os.remove(raw)
        with open(os.path.join(folder, "Contents.json"), "w") as f:
            json.dump({"images": [{"filename": "photo.jpg", "idiom": "universal"}], "info": {"author": "xcode", "version": 1}}, f, indent=2)
        credit = " · ".join(x for x in [meta["artist"], meta["licenceName"]] if x)
        kept.append({"asset": name, "caption": p.get("caption", "").strip().rstrip("."), "credit": credit, "source": meta["page"]})
        time.sleep(0.3)
    if kept:
        photos[pick["id"]] = kept

for path in LORE:
    entries = json.load(open(path))
    for e in entries:
        if e["id"] in photos:
            e["photos"] = photos[e["id"]]
    with open(path, "w") as f:
        json.dump(entries, f, indent=2, ensure_ascii=False)
        f.write("\n")

print(f"{sum(len(v) for v in photos.values())} photos for {len(photos)} secrets")
print(f"dropped {len(dropped)}:")
for d in dropped:
    print("  " + d)
