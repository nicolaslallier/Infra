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

# main() end to end with embed stubbed: SQL shape, COPY rows read back.
import io, json, os, contextlib, unicodedata  # noqa: E402


def run_main(vault, state_text, *extra):
    st = vault.parent / "st"
    st.write_text(state_text)
    out = io.StringIO()
    argv, sys.argv = sys.argv, ["x", "--vault", str(vault), "--state", str(st), *extra]
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            iv.main()
    finally:
        sys.argv = argv
    return out.getvalue()


def unescape(line):
    import re
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t", "r": "\r"}.get(m.group(1), m.group(1)), line)


iv.embed = lambda texts, url, key: [[0.0] * iv.DIM for _ in texts]
os.environ.setdefault("LITELLM_URL", "http://stub")
os.environ.setdefault("LITELLM_MASTER_KEY", "stub")
with tempfile.TemporaryDirectory() as d:
    v = pathlib.Path(d) / "v"
    v.mkdir()
    (v / "a.md").write_text('# T\n\nback\\slash\ttab "q"\x00 fin')
    (v / "b.md").write_text("garde")
    # NFD file name, excluded folder in NFD too.
    nfd = unicodedata.normalize("NFD", "06 - Modèles")
    (v / nfd).mkdir()
    (v / nfd / "t.md").write_text("x")
    keep = iv.sha("garde")
    sql = run_main(v, f"b.md\t{keep}\nold.md\tzzz\n")
    head, rest = sql.split("COPY vault_in (j) FROM STDIN;\n", 1)
    assert head.index("SET ROLE litellm_rag;") < head.index("CREATE TEMP TABLE"), head
    data, tail = rest.split("\\.\n", 1)
    assert tail == iv.SQL_TAIL[3:] and "SET ROLE" not in tail
    rows = [json.loads(unescape(l)) for l in data.splitlines()]
    assert {"purge": "old.md"} in rows, rows
    ins = [r for r in rows if "content" in r]
    assert len(ins) == 1 and ins[0]["metadata"]["path"] == "a.md", ins
    assert 'back\\slash\ttab "q" fin' in ins[0]["content"] and "\x00" not in ins[0]["content"]
    assert len(json.loads(ins[0]["embedding"])) == iv.DIM
    assert not any("Mod" in r.get("metadata", {}).get("path", "") for r in ins)

    # Partial vault: over half the index missing -> refuse unless --force.
    state = "".join(f"gone{i}.md\tx\n" for i in range(3)) + f"b.md\t{keep}\n"
    try:
        run_main(v, state)
        raise AssertionError("partial vault not refused")
    except SystemExit as e:
        assert "refusing" in str(e.code)
    assert "gone0.md" in run_main(v, state, "--force")

# COPY escaping.
assert iv.copy_escape('a\\b\tc\n"d"') == 'a\\\\b\\tc\\n"d"'
print("ok")
