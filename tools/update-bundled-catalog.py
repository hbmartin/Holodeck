#!/usr/bin/env python3
"""Fetch one validated published snapshot; ordinary builds never run this command."""
import datetime
import hashlib
import json
import pathlib
import re
import tempfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
API = "https://api.github.com/repos/hbmartin/HolodeckShaders"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fetch(path, raw=False, limit=2_097_152):
    request = urllib.request.Request(API + path, headers={
        "Accept": "application/vnd.github.raw+json" if raw else "application/vnd.github+json",
        "User-Agent": "Holodeck-bundle-export", "X-GitHub-Api-Version": "2022-11-28"})
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError("Oversized catalog asset")
    return data


def main():
    revision = json.loads(fetch("/git/ref/heads/published"))["object"]["sha"]
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Invalid publication revision")
    manifest = json.loads(fetch(f"/contents/catalog.json?ref={revision}", raw=True))
    entries = manifest["shaders"]
    ids = [entry["id"] for entry in entries]
    if manifest["schemaVersion"] != 1 or not 1 <= len(ids) <= 500 or len(set(ids)) != len(ids) or manifest["defaultShaderID"] not in ids:
        raise ValueError("Invalid catalog schema, IDs or default")
    if not re.fullmatch(r"[0-9a-f]{40}", manifest["sourceRevision"]):
        raise ValueError("Invalid authoring revision")
    sources, images = {}, {}
    for entry in entries:
        shader_id = entry["id"]
        if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", shader_id) or len(shader_id) > 100:
            raise ValueError("Invalid shader ID")
        if entry["category"] not in ("PROCEDURAL", "3D MATERIAL") or not entry["name"].strip() or not entry["description"].strip():
            raise ValueError("Invalid metadata")
        if len(entry["name"]) > 200 or len(entry["description"]) > 2000:
            raise ValueError("Oversized metadata")
        if len(entry["colors"]) != 2 or any(len(c) != 3 or any(type(v) not in (int, float) or not 0 <= v <= 1 for v in c) for c in entry["colors"]):
            raise ValueError("Invalid card colors")
        date = datetime.datetime.fromisoformat(entry["updatedAt"].replace("Z", "+00:00"))
        if date.tzinfo is None:
            raise ValueError("Update dates require a timezone")
        if entry["sourcePath"] != f"sources/{shader_id}.metal" or entry["previewPath"] != f"previews/{shader_id}.png":
            raise ValueError("Invalid asset path")
        for key in ("sourceSHA256", "previewSHA256"):
            if not re.fullmatch(r"[0-9a-f]{64}", entry[key]):
                raise ValueError("Invalid hash")
        source = fetch(f"/contents/{entry['sourcePath']}?ref={revision}", raw=True, limit=1_048_576)
        image = fetch(f"/contents/{entry['previewPath']}?ref={revision}", raw=True, limit=8_388_608)
        if not source or sha(source) != entry["sourceSHA256"] or sha(image) != entry["previewSHA256"] or not image.startswith(b"\x89PNG\r\n\x1a\n"):
            raise ValueError(f"Invalid assets for {shader_id}")
        sources[shader_id] = source.decode("utf-8")
        images[entry["previewSHA256"]] = image
    if sum(len(s.encode()) for s in sources.values()) > 16_777_216:
        raise ValueError("Catalog sources exceed 16 MiB")
    snapshot = {"manifest": manifest, "sources": sources, "publicationRevision": revision}
    # Fetch and validate everything before changing any checked-in resource.
    destination = ROOT / "Holodeck/BundledCatalog"
    destination.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as temp:
        stage = pathlib.Path(temp)
        (stage / "BundledCatalog.json").write_text(json.dumps(snapshot, indent=2, sort_keys=True) + "\n")
        for digest, image in images.items():
            (stage / f"preview-{digest}.png").write_bytes(image)
        for file in stage.iterdir():
            file.replace(destination / file.name)
        expected = {f"preview-{digest}.png" for digest in images}
        for file in destination.glob("preview-*.png"):
            if file.name not in expected:
                file.unlink()
    print(f"Exported {len(entries)} shaders from published commit {revision}")


if __name__ == "__main__":
    main()
