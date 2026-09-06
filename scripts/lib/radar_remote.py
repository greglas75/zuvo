"""Read-only PR evidence. Missing/partial providers never mean FREE."""

from __future__ import annotations

import base64
import json
import os
from pathlib import Path
import re
import shutil
import sys
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

import radar_io

MAX_PAGES = 50
PAGE_SIZE = 100
MAX_BODY = 8 * 1024 * 1024
SLUG = re.compile(r"[\w.-]+/[\w.-]+", re.ASCII)


def command(argv: list[str], root: Path) -> str:
    """Do not expose stderr/argv: provider failures can contain credentials."""
    return radar_io.command(argv, root, limit=MAX_BODY, timeout=30).decode("utf-8")


def safe_path(value: Any) -> str:
    if (
        not isinstance(value, str)
        or not value
        or value.startswith("/")
        or re.match(r"^[A-Za-z]:", value)
        or any(p in ("", ".", "..") for p in value.split("/"))
        or any(ord(c) < 32 for c in value)
        or "\\" in value
    ):
        raise ValueError("invalid repository-relative path")
    return value


def remote_location(url: str) -> tuple[str, str]:
    """Parse a URL or scp-like remote; never infer provider from a path substring."""
    if "://" in url:
        parsed = urlsplit(url)
        host, path = parsed.netloc.rsplit("@", 1)[-1].lower(), parsed.path
    else:
        match = re.fullmatch(r"(?:[^/@:]+@)?([^/:]+):(.+)", url)
        host, path = (match.group(1).lower(), match.group(2)) if match else ("", "")
    return host, path.strip("/").removesuffix(".git")


def gh_pages(root: Path, endpoint: str) -> list[dict]:
    records: list[dict] = []
    seen: set[str] = set()
    for page in range(1, MAX_PAGES + 1):
        sep = "&" if "?" in endpoint else "?"
        raw = command(["gh", "api", f"{endpoint}{sep}per_page={PAGE_SIZE}&page={page}"], root)
        data = json.loads(raw)
        if not isinstance(data, list) or not all(isinstance(r, dict) for r in data):
            raise ValueError("GitHub: malformed page")
        if data and raw in seen:
            raise ValueError("GitHub: repeated page")
        seen.add(raw)
        records.extend(data)
        if len(data) < PAGE_SIZE:
            return records
    raise ValueError("GitHub: pagination limit reached")


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req: Any, fp: Any, code: int, msg: str, headers: Any, newurl: str) -> None:
        return None


def bb_page(url: str, prefix: str, auth: str) -> dict:
    parsed = urlsplit(url)
    if (
        parsed.scheme != "https"
        or parsed.netloc != "api.bitbucket.org"
        or not parsed.path.startswith(prefix + "/")
        or parsed.username
        or any(part in (".", "..") for part in parsed.path.split("/"))
        or any(c.isspace() or ord(c) < 32 for c in url)
        or "\\" in url
        or "%" in parsed.path
    ):
        raise ValueError("Bitbucket: unsafe pagination URL")
    request = Request(url, headers={"Authorization": "Basic " + auth})
    with build_opener(NoRedirect()).open(request, timeout=20) as response:
        body = response.read(MAX_BODY + 1)
    if len(body) > MAX_BODY:
        raise ValueError("Bitbucket: response exceeded limit")
    data = json.loads(body)
    if not isinstance(data, dict):
        raise ValueError("Bitbucket: malformed page")
    return data


def bb_pages(url: str, prefix: str, auth: str) -> list[dict]:
    records: list[dict] = []
    seen: set[str] = set()
    for _ in range(MAX_PAGES):
        if url in seen:
            raise ValueError("Bitbucket: repeated page")
        seen.add(url)
        data = bb_page(url, prefix, auth)
        values = data.get("values")
        if not isinstance(values, list) or not all(isinstance(r, dict) for r in values):
            raise ValueError("Bitbucket: malformed values")
        records.extend(values)
        next_url = data.get("next")
        if next_url is None:
            return records
        if not isinstance(next_url, str) or not next_url:
            raise ValueError("Bitbucket: malformed next URL")
        url = next_url
    raise ValueError("Bitbucket: pagination limit reached")


def promotion(head: str, base: str, cfg: dict, source: Any, destination: Any, slug: str) -> bool:
    return (
        [head, base] in cfg.get("promotion_branches", [])
        and isinstance(source, dict)
        and isinstance(destination, dict)
        and str(source.get("full_name", "")).lower() == slug.lower()
        and str(destination.get("full_name", "")).lower() == slug.lower()
    )


def pr_identity(head: Any, base: Any, sha: Any) -> None:
    if not all(isinstance(v, str) and v for v in (head, base, sha)) or not re.fullmatch(
        r"[a-fA-F0-9]{40,64}", sha
    ):
        raise ValueError("PR identity incomplete")


def github(root: Path, slug: str, cfg: dict, evidence: dict) -> None:
    for pr in gh_pages(root, f"repos/{slug}/pulls?state=open"):
        number = pr["number"]
        if type(number) is not int or number < 1:
            raise ValueError("GitHub: invalid PR number")
        head, base = pr["head"]["ref"], pr["base"]["ref"]
        pr_identity(head, base, pr["head"]["sha"])
        if promotion(head, base, cfg, pr["head"].get("repo"), pr["base"].get("repo"), slug):
            evidence["promotions"].append(number)
            continue
        files = gh_pages(root, f"repos/{slug}/pulls/{number}/files")
        # GitHub's file endpoint has a hard 3000-file ceiling.
        if len(files) >= 3000:
            raise ValueError("GitHub: file census may be truncated at 3000")
        for file in files:
            evidence["paths"].append(safe_path(file["filename"]))
            if "previous_filename" in file:
                evidence["paths"].append(safe_path(file["previous_filename"]))
        evidence["prs"].append({"id": number, "head": head, "sha": pr["head"]["sha"], "base": base})


def bitbucket(root: Path, slug: str, cfg: dict, evidence: dict) -> None:
    token = os.environ.get("RADAR_BB_TOKEN", "")
    if not token and sys.platform == "darwin" and shutil.which("security"):
        token = command(
            ["security", "find-generic-password", "-s", "bitbucket-api-token", "-w"], root
        ).strip()
    user = cfg.get("bb_user", "")
    if not token or not user:
        raise ValueError("Bitbucket: credentials unavailable; no credential repair attempted")
    auth = base64.b64encode(f"{user}:{token}".encode()).decode()
    prefix = f"/2.0/repositories/{slug}"
    url = f"https://api.bitbucket.org{prefix}/pullrequests?state=OPEN&pagelen=100"
    for pr in bb_pages(url, prefix, auth):
        number = pr["id"]
        if type(number) is not int or number < 1:
            raise ValueError("Bitbucket: invalid PR id")
        head, base = pr["source"]["branch"]["name"], pr["destination"]["branch"]["name"]
        pr_identity(head, base, pr["source"]["commit"]["hash"])
        if promotion(
            head, base, cfg, pr["source"].get("repository"), pr["destination"].get("repository"), slug
        ):
            evidence["promotions"].append(number)
            continue
        files = bb_pages(
            f"https://api.bitbucket.org{prefix}/pullrequests/{number}/diffstat?pagelen=100", prefix, auth
        )
        for file in files:
            if not {"old", "new"}.issubset(file) or all(file[side] is None for side in ("old", "new")):
                raise ValueError("Bitbucket: malformed diffstat entry")
            for side in ("old", "new"):
                if file.get(side) is not None:
                    evidence["paths"].append(safe_path(file[side]["path"]))
        evidence["prs"].append(
            {"id": number, "head": head, "sha": pr["source"]["commit"]["hash"], "base": base}
        )


def collect(root: Path, cfg: dict, disabled: bool, remote_url: str) -> dict:
    evidence: dict = {"complete": False, "paths": [], "prs": [], "promotions": [], "errors": []}
    provider = cfg.get("remote", "auto")
    if disabled:
        evidence["errors"].append("PR lookup skipped (--no-remote); availability UNKNOWN")
        return evidence
    if provider == "none":
        evidence.update(complete=True, provider="none", reason="profile declares PRs not applicable")
        return evidence
    host, remote_slug = remote_location(remote_url)
    if provider == "auto":
        provider = {"bitbucket.org": "bb", "github.com": "gh"}.get(host, "unknown")
    evidence["provider"] = provider
    slug = cfg.get("bb_repo" if provider == "bb" else "gh_repo")
    if not slug:
        slug = remote_slug if host == {"bb": "bitbucket.org", "gh": "github.com"}.get(provider) else ""
    try:
        if (
            not isinstance(slug, str)
            or not SLUG.fullmatch(slug)
            or any(p in (".", "..") for p in slug.split("/"))
        ):
            raise ValueError("authoritative PR repository is unknown")
        if provider == "gh":
            github(root, slug, cfg, evidence)
        elif provider == "bb":
            bitbucket(root, slug, cfg, evidence)
        else:
            raise ValueError("authoritative PR provider is unknown")
        evidence["complete"] = True
    except (ValueError, KeyError, TypeError, UnicodeError, HTTPError, URLError, OSError) as err:
        # Never serialize the exception payload; HTTP/CLI errors may echo auth details.
        evidence["errors"].append(f"{provider}: PR census incomplete ({type(err).__name__})")
    evidence["paths"] = sorted(set(evidence["paths"]))
    return evidence
