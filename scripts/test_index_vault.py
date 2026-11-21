"""Plain-assert tests for scripts/index_vault.py (no network). Run by scripts/test.sh."""
import pathlib
import subprocess
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import index_vault as iv  # noqa: E402

# Chunking: frontmatter gone, prefix, ceiling, empty note.
text = "---\ntags: [x]\n---\n# Titre\n\n" + "\n\n".join("mot " * 60 for _ in range(20)) + "\n\n" + "z" * 4000
cs = iv.chunks("a/b.md", text)
assert cs and all(c.startswith("a/b.md > Titre\n\n") for c in cs), cs[0][:40]
assert all(len(c.split("\n\n", 1)[1]) <= iv.MAX_CHARS for c in cs)
assert not any("tags:" in c for c in cs)
assert iv.chunks("vide.md", "") == [] and iv.chunks("v.md", "---\na: 1\n---\n\n") == []

# Diff: the four cases.
assert iv.diff({"n": "1", "m": "2", "u": "3"}, {"m": "x", "u": "3", "d": "4"}) == (["n"], ["m"], ["d"], ["u"])

with tempfile.TemporaryDirectory() as d:
    v = pathlib.Path(d)
    for rel in ("ok.md", "sous/ok.md", ".obsidian/x.md", ".trash/x.md", ".git/x.md", "06 - Modèles/t.md", "n.txt"):
        (v / rel).parent.mkdir(parents=True, exist_ok=True)
        (v / rel).write_text("x")
    assert sorted(iv.notes(v)) == ["ok.md", "sous/ok.md"], iv.notes(v)

    # Empty vault: abort, never empty the index.
    empty = v / "vide"
    empty.mkdir()
    state = v / "state"
    state.write_text("ok.md\tabc\n")
    r = subprocess.run([sys.executable, iv.__file__, "--vault", str(empty), "--state", str(state)],
                       capture_output=True, text=True)
    assert r.returncode != 0 and not r.stdout and "refusing" in r.stderr, r

# COPY escaping.
assert iv.copy_escape('a\\b\tc\n"d"') == 'a\\\\b\\tc\\n"d"'
print("ok")
