"""Read-only access to an Obsidian vault kept in S3 (the `obsidian` bucket, synced by Remotely Save).

Only `.md` files, never under `.obsidian/`, paths normalised, reads capped, searches bounded.
There is deliberately no write call anywhere in this module: the S3 identity behind it is
`Read,List` only, and a test greps this file for put/delete/copy.
"""
import unicodedata

from botocore.exceptions import ClientError

MAX_READ_BYTES = 1_048_576  # 1 MiB
MAX_SCAN_OBJECTS = 500      # notes considered by one search
MAX_LIST_KEYS = 10_000      # keys looked at by one listing, notes or not
SNIPPET_CHARS = 200
_PAGE = 1000


def normalize_path(path: str) -> str:
    """A vault-relative path with no way out of the vault; ValueError otherwise."""
    if not isinstance(path, str) or not path:
        raise ValueError("empty path")
    if "\x00" in path or "\\" in path or path.startswith("/"):
        raise ValueError("invalid path")
    parts = [p for p in unicodedata.normalize("NFC", path).split("/") if p not in ("", ".")]
    if not parts or ".." in parts:
        raise ValueError("invalid path")
    return "/".join(parts)


def is_note_key(key: str) -> bool:
    return key.endswith(".md") and ".obsidian" not in key.split("/")[:-1]


def _prefix(vault_prefix: str) -> str:
    return vault_prefix if not vault_prefix or vault_prefix.endswith("/") else vault_prefix + "/"


def _folder(prefix: str) -> str:
    if not prefix:
        return ""
    return normalize_path(prefix) + ("/" if prefix.endswith("/") else "")


def _note_keys(s3, bucket: str, prefix: str, vault_prefix: str, max_keys: int):
    """(path, size) of the notes under `prefix`, vault prefix stripped, looking at <= max_keys keys."""
    vp = _prefix(vault_prefix)
    seen, token = 0, None
    while True:
        kw = {"Bucket": bucket, "Prefix": vp + _folder(prefix), "MaxKeys": _PAGE}
        if token:
            kw["ContinuationToken"] = token
        page = s3.list_objects_v2(**kw)
        for obj in page.get("Contents", []):
            seen += 1
            path = obj["Key"][len(vp):]
            if is_note_key(path):
                yield path, obj["Size"]
            if seen >= max_keys:
                return
        if not page.get("IsTruncated"):
            return
        token = page.get("NextContinuationToken")


def list_notes(s3, bucket: str, prefix: str = "", limit: int = 200, vault_prefix: str = "") -> list[str]:
    out: list[str] = []
    for path, _ in _note_keys(s3, bucket, prefix, vault_prefix, MAX_LIST_KEYS):
        out.append(path)
        if len(out) >= limit:
            break
    return out


def _get_text(s3, bucket: str, key: str) -> str:
    try:
        resp = s3.get_object(Bucket=bucket, Key=key)
    except ClientError as e:
        raise ValueError("note not found") from e
    if resp["ContentLength"] > MAX_READ_BYTES:
        resp["Body"].close()
        raise ValueError(f"note is larger than {MAX_READ_BYTES} bytes")
    return resp["Body"].read().decode("utf-8", errors="replace")


def read_note(s3, bucket: str, path: str, vault_prefix: str = "") -> str:
    path = normalize_path(path)
    if not is_note_key(path):
        raise ValueError("not a note (only .md files outside .obsidian/)")
    return _get_text(s3, bucket, _prefix(vault_prefix) + path)


def search_notes(s3, bucket: str, query: str, prefix: str = "", limit: int = 20, vault_prefix: str = "") -> list[dict]:
    if not query or len(query) > 200:
        raise ValueError("query must be 1-200 characters")
    needle, hits, scanned = query.lower(), [], 0
    for path, size in _note_keys(s3, bucket, prefix, vault_prefix, MAX_LIST_KEYS):
        if scanned >= MAX_SCAN_OBJECTS:
            hits.append({"truncated": f"scan stopped after {MAX_SCAN_OBJECTS} notes; narrow with prefix"})
            break
        scanned += 1
        if size > MAX_READ_BYTES:
            continue
        text = _get_text(s3, bucket, _prefix(vault_prefix) + path)
        i = text.lower().find(needle)
        if i < 0:
            continue
        room = max(SNIPPET_CHARS - len(query), 0) // 2
        snippet = " ".join(text[max(i - room, 0): i + len(query) + room].split())
        hits.append({"path": path, "snippet": snippet[:SNIPPET_CHARS]})
        if len(hits) >= limit:
            break
    return hits
