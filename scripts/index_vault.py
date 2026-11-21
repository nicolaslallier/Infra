#!/usr/bin/env python3
"""Index the Obsidian vault into LiteLLM's `second-brain` vector store.

Run by scripts/index-vault.sh (make index-vault). Reads the current state
(path<TAB>sha256 per indexed note, from the database), walks the vault,
embeds only new/changed notes through LiteLLM, and prints on stdout one psql
script that applies the change in one transaction. Stdlib only.

litellm-pgvector has no delete/upsert route, so rows go in through SQL; every
value travels as JSON in a COPY block, never spliced into SQL text.
"""
import argparse
import hashlib
import json
import os
import pathlib
import ssl
import sys
import unicodedata
import urllib.request

EXCLUDED = (".obsidian/", ".trash/", ".git/", "06 - Modèles/")
SOURCE = "obsidian-maison"
STORE = "second-brain"
MODEL = "qwen3-embedding:0.6b"
DIM = 1024
MAX_CHARS = 1500
BATCH = 32


def notes(vault):
    """{relative path: text} of every indexable .md note."""
    out = {}
    for p in sorted(vault.rglob("*.md")):
        # macOS may hand back NFD names: compare (and store) in NFC.
        rel = unicodedata.normalize("NFC", p.relative_to(vault).as_posix())
        if not any(rel.startswith(e) or f"/{e}" in rel for e in EXCLUDED):
            out[rel] = p.read_text(encoding="utf-8", errors="replace").replace("\x00", "")
    return out


def sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def diff(current, state):
    """(new, changed, deleted, unchanged) lists of paths; current/state: {path: sha256}."""
    new = [p for p in current if p not in state]
    changed = [p for p in current if p in state and state[p] != current[p]]
    deleted = [p for p in state if p not in current]
    unchanged = [p for p in current if state.get(p) == current[p]]
    return new, changed, deleted, unchanged


def chunks(path, text):
    """Frontmatter stripped, paragraphs grouped up to ~MAX_CHARS, each prefixed `path > heading`."""
    if text.startswith("---\n"):
        end = text.find("\n---", 4)
        if end != -1:
            text = text[end + 4:]
    out, buf, title = [], "", ""

    def flush():
        nonlocal buf
        if buf.strip():
            out.append(f"{path} > {title}\n\n{buf.strip()}" if title else f"{path}\n\n{buf.strip()}")
        buf = ""

    for para in (p.strip() for p in text.split("\n\n")):
        if not para:
            continue
        if para.startswith("#"):
            flush()
            title = para.splitlines()[0].lstrip("#").strip()
        # ponytail: a single paragraph over MAX_CHARS is cut hard, not on sentences.
        while len(para) > MAX_CHARS:
            flush()
            buf = para[:MAX_CHARS]
            flush()
            para = para[MAX_CHARS:]
        if buf and len(buf) + len(para) + 2 > MAX_CHARS:
            flush()
        buf = f"{buf}\n\n{para}" if buf else para
    flush()
    return out


def embed(texts, url, key):
    req = urllib.request.Request(
        url, data=json.dumps({"model": MODEL, "input": texts}).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    ca = pathlib.Path(__file__).resolve().parent.parent / "certs" / "infra-ca.crt"
    ctx = ssl.create_default_context(cafile=str(ca)) if ca.exists() else None
    with urllib.request.urlopen(req, timeout=300, context=ctx) as r:
        data = sorted(json.load(r)["data"], key=lambda d: d["index"])
    vecs = [d["embedding"] for d in data]
    assert len(vecs) == len(texts), "embedding count mismatch"
    for v in vecs:
        assert len(v) == DIM, f"embedding has {len(v)} dims, expected {DIM}"
    return vecs


def copy_escape(s):
    """Escape one value for COPY text format."""
    return s.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")


SQL_HEAD = r"""\set ON_ERROR_STOP on
SET ROLE litellm_rag;
CREATE TEMP TABLE vault_in (j jsonb);
COPY vault_in (j) FROM STDIN;
"""

SQL_TAIL = r"""\.
DELETE FROM embeddings
 WHERE vector_store_id = 'second-brain' AND metadata->>'source' = 'obsidian-maison'
   AND metadata->>'path' IN (SELECT j->>'purge' FROM vault_in WHERE j ? 'purge');
INSERT INTO embeddings (vector_store_id, content, embedding, metadata)
SELECT 'second-brain', j->>'content', (j->>'embedding')::vector, j->'metadata'
  FROM vault_in WHERE j ? 'content';
UPDATE vector_stores SET
  file_counts = jsonb_build_object('in_progress', 0, 'completed', s.files, 'failed', 0,
                                   'cancelled', 0, 'total', s.files),
  usage_bytes = s.bytes, last_active_at = now()
  FROM (SELECT count(DISTINCT metadata->>'filename') AS files,
               coalesce(sum(octet_length(content)), 0) AS bytes
          FROM embeddings WHERE vector_store_id = 'second-brain') s
 WHERE id = 'second-brain';
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vault", required=True, type=pathlib.Path)
    ap.add_argument("--state", required=True, type=pathlib.Path)
    ap.add_argument("--force", action="store_true", help="allow deleting over half the index")
    a = ap.parse_args()

    texts = notes(a.vault)
    if not texts:
        sys.exit(f"index_vault.py: no notes in {a.vault}; refusing to empty the index")
    state = dict(l.split("\t", 1) for l in a.state.read_text().splitlines() if "\t" in l)
    current = {p: sha(t) for p, t in texts.items()}
    new, changed, deleted, unchanged = diff(current, state)
    if state and len(deleted) * 2 > len(state) and not a.force:
        sys.exit(f"index_vault.py: {len(deleted)}/{len(state)} indexed notes missing from {a.vault} "
                 "(partial vault?); refusing, force=1 to override")

    rows = [{"purge": p} for p in changed + deleted]
    pending = [(p, i, c) for p in new + changed for i, c in enumerate(chunks(p, texts[p]))]
    url = os.environ["LITELLM_URL"].rstrip("/") + "/v1/embeddings"
    for b in range(0, len(pending), BATCH):
        part = pending[b:b + BATCH]
        for (p, i, c), v in zip(part, embed([c for _, _, c in part], url, os.environ["LITELLM_MASTER_KEY"])):
            rows.append({"content": c, "embedding": json.dumps(v), "metadata": {
                "source": SOURCE, "path": p, "filename": p, "sha256": current[p], "chunk": i}})
        print(f"index_vault.py: embedded {b + len(part)}/{len(pending)}", file=sys.stderr)

    sys.stdout.write(SQL_HEAD)
    for r in rows:
        sys.stdout.write(copy_escape(json.dumps(r, ensure_ascii=False)) + "\n")
    sys.stdout.write(SQL_TAIL)
    print(f"index_vault.py: {len(new)} nouvelles, {len(changed)} modifiées, {len(deleted)} supprimées, "
          f"{len(unchanged)} inchangées, {len(pending)} morceaux", file=sys.stderr)


if __name__ == "__main__":
    main()
