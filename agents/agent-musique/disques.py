"""agent-musique: Nicolas's record collection, in his Obsidian vault (bucket `obsidian`, S3 copy).

Pure logic, the S3 client and the LLM call are injected (server.py builds them, the tests stub
them). Everything stays under `<vault_prefix>02 - Domaines/Loisirs/Musique/`: reads and writes go
through cle_ecriture(), and _ecrire() is the one function that writes. This module never removes
or copies an object (a test greps it). The model never picks a path: nom_note() does.
"""
import json
import re
import unicodedata
from datetime import datetime, timedelta

from botocore.exceptions import ClientError

MUSIQUE = "02 - Domaines/Loisirs/Musique/"
INDEX = MUSIQUE + "Discographie.md"
MAX_TOURS = 6
MAX_READ_BYTES = 1_048_576
MAX_SCAN = 500
CLES_AGENT = ("artiste", "titre", "format", "annee", "label")
_INTERDITS = re.compile(r'[/\\:*?"<>|#^\[\]\x00-\x1f]')

PROMPT = """Tu es agent-musique, l'assistant de Nicolas pour sa collection de disques.
Ses notes Obsidian font foi. Règles :
1. Réponds d'abord depuis ses notes : l'index Discographie ci-dessous, et les outils lire_disque et chercher.
2. Si ce n'est pas dans les notes, dis « pas dans ta collection » ou « je ne sais pas ». N'invente jamais un disque, un format, une année ni un label.
3. Ta réponse a deux sections séparées : « Dans ta collection » (seulement ce que disent les notes) et « Connaissance générale (non vérifiée) » (ce que tu sais par ailleurs, ou « rien à ajouter »).
4. Pour enregistrer un disque, appelle enregistrer_disque ; ne prétends jamais l'avoir fait sans l'appel.
5. N'écris pas de ligne « Sources : », le système l'ajoute.
Le chemin d'une note est le lien de l'index sans [[ ]], suivi de .md.

Index (Discographie.md) :
"""

OUTILS = [
    {"type": "function", "function": {
        "name": "lire_disque", "description": "Lire une note de disque par son chemin dans le coffre.",
        "parameters": {"type": "object", "properties": {"chemin": {"type": "string"}}, "required": ["chemin"]}}},
    {"type": "function", "function": {
        "name": "chercher", "description": "Chercher un texte (sans casse) dans les notes de musique.",
        "parameters": {"type": "object", "properties": {"texte": {"type": "string"}}, "required": ["texte"]}}},
    {"type": "function", "function": {
        "name": "enregistrer_disque",
        "description": "Créer la note d'un disque, ou la mettre à jour si elle existe déjà.",
        "parameters": {"type": "object", "properties": {
            "artiste": {"type": "string"}, "titre": {"type": "string"},
            "format": {"type": "string", "description": "vinyle, CD, cassette..."},
            "annee": {"type": "string"}, "label": {"type": "string"},
            "etat": {"type": "string"}, "notes": {"type": "string"}},
            "required": ["artiste", "titre", "format"]}}},
]


def normalize_path(path: str) -> str:
    """A vault-relative path with no way out of the vault; ValueError otherwise (from mcp/obsidian/notes.py)."""
    if not isinstance(path, str) or not path:
        raise ValueError("empty path")
    if "\x00" in path or "\\" in path or path.startswith("/"):
        raise ValueError("invalid path")
    parts = [p for p in unicodedata.normalize("NFC", path).split("/") if p not in ("", ".")]
    if not parts or ".." in parts:
        raise ValueError("invalid path")
    return "/".join(parts)


def _vp(vault_prefix: str) -> str:
    return vault_prefix if not vault_prefix or vault_prefix.endswith("/") else vault_prefix + "/"


def cle_ecriture(cle: str, vault_prefix: str) -> str:
    """The key itself if it is a .md note under the Musique folder, ValueError otherwise."""
    vp = _vp(vault_prefix)
    if not isinstance(cle, str) or not cle.startswith(vp + MUSIQUE) or not cle.endswith(".md"):
        raise ValueError(f"hors du dossier {MUSIQUE} ou pas une note .md")
    rel = cle[len(vp):]
    if normalize_path(rel) != rel or ".obsidian" in rel.split("/"):
        raise ValueError("chemin invalide")
    return cle


def cle_lecture(chemin: str, vault_prefix: str) -> str:
    """Reads are held to the same folder as writes."""
    chemin = chemin.strip().removeprefix("[[").removesuffix("]]")
    if not chemin.endswith(".md"):
        chemin += ".md"
    return cle_ecriture(_vp(vault_prefix) + normalize_path(chemin), vault_prefix)


def nom_note(artiste: str, titre: str, format: str) -> str:
    """`Artiste - Titre (format).md`, NFC, without the characters Obsidian or S3 choke on."""
    def propre(s):
        s = " ".join(_INTERDITS.sub(" ", unicodedata.normalize("NFC", str(s or ""))).split()).strip(". ")
        if not s:
            raise ValueError("artiste, titre et format sont requis")
        return s
    return f"{propre(artiste)} - {propre(titre)} ({propre(format)}).md"


def _absente(e: ClientError) -> bool:
    return e.response.get("Error", {}).get("Code") in ("404", "NoSuchKey", "NotFound")


def _lire_cle(s3, bucket: str, cle: str) -> str:
    body = s3.get_object(Bucket=bucket, Key=cle)["Body"]
    return body.read(MAX_READ_BYTES).decode("utf-8", errors="replace")


def _ecrire(s3, bucket: str, cle: str, texte: str, vault_prefix: str) -> None:
    """The only write in this module."""
    s3.put_object(Bucket=bucket, Key=cle_ecriture(cle, vault_prefix), Body=texte.encode("utf-8"),
                  ContentType="text/markdown; charset=utf-8")


def _notes(s3, bucket: str, vault_prefix: str):
    """Keys of the notes under the Musique folder (the index excluded), at most MAX_SCAN."""
    vp, token, n = _vp(vault_prefix), None, 0
    while True:
        kw = {"Bucket": bucket, "Prefix": vp + MUSIQUE}
        if token:
            kw["ContinuationToken"] = token
        page = s3.list_objects_v2(**kw)
        for o in page.get("Contents", []):
            k = o["Key"]
            if k != vp + INDEX and k.endswith(".md") and ".obsidian" not in k.split("/"):
                n += 1
                yield k
                if n >= MAX_SCAN:
                    return
        token = page.get("NextContinuationToken")
        if not page.get("IsTruncated") or not token:
            return


def lire_frontmatter(texte: str) -> dict:
    """The single-line `key: value` pairs of the frontmatter (values written by _fm_ligne)."""
    m = re.match(r"---\n(.*?)\n---\n", texte, re.S)
    out = {}
    for ligne in (m.group(1).split("\n") if m else []):
        k, sep, v = ligne.partition(":")
        if sep and k and not k.startswith((" ", "-", "#")):
            v = v.strip()
            try:
                v = json.loads(v) if v.startswith('"') else v
            except ValueError:
                pass
            out[k.strip()] = v
    return out


def _fm_ligne(k: str, v: str) -> str:
    return f"{k}: {json.dumps(str(v), ensure_ascii=False)}"


def note_neuve(champs: dict, ligne: str) -> str:
    fm = "\n".join(["type: disque", "tags: [musique, disque]", "source: claude"]
                   + [_fm_ligne(k, champs[k]) for k in CLES_AGENT if champs.get(k)])
    return f"---\n{fm}\n---\n# {champs['artiste']} - {champs['titre']}\n\n## Notes\n{ligne}\n"


def mise_a_jour(texte: str, champs: dict, ligne: str) -> str:
    """Change only the agent's own frontmatter lines, add `ligne` under `## Notes`; the rest stays byte for byte."""
    m = re.match(r"---\n(.*?)\n---\n", texte, re.S)
    if m:
        lignes, fin = m.group(1).split("\n"), m.end()
        for k in CLES_AGENT:
            if not champs.get(k):
                continue
            neuve = _fm_ligne(k, champs[k])
            i = next((i for i, ln in enumerate(lignes) if re.match(rf"{k}\s*:", ln)), None)
            if i is None:
                lignes.append(neuve)
            else:
                lignes[i] = neuve
        texte = "---\n" + "\n".join(lignes) + "\n---\n" + texte[fin:]
    t = re.search(r"^## Notes[ \t]*\n", texte, re.M)
    if not t:
        return texte + ("" if texte.endswith("\n") else "\n") + f"\n## Notes\n{ligne}\n"
    suite = re.search(r"^#{1,2} ", texte[t.end():], re.M)
    pos = t.end() + suite.start() if suite else len(texte)
    corps = texte[t.end():pos]
    coeur = corps.rstrip("\n")
    fin = corps[len(coeur):]
    neuf = (coeur + "\n" + ligne + (fin or "\n")) if coeur else (ligne + "\n" + fin)
    return texte[:t.end()] + neuf + texte[pos:]


def _cellule(v) -> str:
    return str(v or "").replace("|", "\\|").replace("\n", " ")


def regenerer_index(s3, bucket: str, vault_prefix: str) -> None:
    """Discographie.md, rebuilt from the frontmatter of every `type: disque` note."""
    vp, rangs = _vp(vault_prefix), []
    for k in _notes(s3, bucket, vault_prefix):
        fm = lire_frontmatter(_lire_cle(s3, bucket, k))
        if fm.get("type") == "disque":
            rangs.append((str(fm.get("artiste", "")).casefold(), str(fm.get("titre", "")).casefold(), fm, k))
    rangs.sort(key=lambda r: r[:2])
    lignes = [f"| {_cellule(fm.get('artiste'))} | {_cellule(fm.get('titre'))} | {_cellule(fm.get('format'))} "
              f"| {_cellule(fm.get('annee'))} | {_cellule(fm.get('label'))} | [[{k[len(vp):-3]}]] |"
              for _, _, fm, k in rangs]
    texte = ("---\ntype: index\ntags: [musique]\nsource: claude\n---\n"
             "> [!warning] Généré par agent-musique à chaque enregistrement : ne pas éditer, "
             "tes changements seraient écrasés. Modifie plutôt la note du disque.\n\n"
             "# Discographie\n\n| Artiste | Titre | Format | Année | Label | Note |\n|---|---|---|---|---|---|\n"
             + "".join(ln + "\n" for ln in lignes))
    _ecrire(s3, bucket, vp + INDEX, texte, vault_prefix)


def enregistrer(s3, bucket: str, vault_prefix: str, now: datetime, quiet_minutes: int,
                artiste: str, titre: str, format: str, annee=None, label=None, etat=None, notes=None) -> tuple[str, str]:
    """(vault path, message). A note touched in the last quiet_minutes is left alone (Remotely Save)."""
    rel = MUSIQUE + nom_note(artiste, titre, format)
    cle = cle_ecriture(_vp(vault_prefix) + rel, vault_prefix)
    champs = {"artiste": artiste, "titre": titre, "format": format, "annee": annee, "label": label}
    champs = {k: " ".join(str(v).split()) for k, v in champs.items() if v not in (None, "")}
    detail = "; ".join(x for x in (f"état : {etat}" if etat else "", notes or "") if x) or "enregistré par agent-musique"
    ligne = f"- {now:%Y-%m-%d} : {' '.join(detail.split())}"
    # ponytail: head then put is not atomic; Remotely Save writing in between loses one side. Add
    # an If-Match on the ETag if SeaweedFS supports it and it ever happens.
    try:
        tete = s3.head_object(Bucket=bucket, Key=cle)
    except ClientError as e:
        if not _absente(e):
            raise
        tete = None
    if tete is None:
        _ecrire(s3, bucket, cle, note_neuve(champs, ligne), vault_prefix)
        msg = "note créée"
    else:
        age = now - tete["LastModified"]
        if age < timedelta(minutes=quiet_minutes):
            return rel, (f"refusé : la note a été modifiée il y a moins de {quiet_minutes} minutes "
                         "(synchro Obsidian en cours ?) ; réessaie plus tard")
        _ecrire(s3, bucket, cle, mise_a_jour(_lire_cle(s3, bucket, cle), champs, ligne), vault_prefix)
        msg = "note existante mise à jour"
    regenerer_index(s3, bucket, vault_prefix)
    return rel, msg


def chercher(s3, bucket: str, vault_prefix: str, texte: str) -> list[dict]:
    vp, q, out = _vp(vault_prefix), str(texte).casefold().strip(), []
    if not q:
        raise ValueError("texte vide")
    for k in _notes(s3, bucket, vault_prefix):
        t = _lire_cle(s3, bucket, k)
        i = t.casefold().find(q)
        if i >= 0 or q in k.casefold():
            out.append({"chemin": k[len(vp):], "extrait": t[max(i, 0):max(i, 0) + 200]})
            if len(out) >= 20:
                break
    return out


def repondre(s3, bucket: str, vault_prefix: str, llm, question: str, now: datetime, quiet_minutes: int = 10) -> str:
    """One answer: index in the system prompt, at most MAX_TOURS model calls, `Sources :` from what was read."""
    vp, sources = _vp(vault_prefix), []
    try:
        index = _lire_cle(s3, bucket, cle_ecriture(vp + INDEX, vault_prefix))
        sources.append(INDEX)
    except ClientError as e:
        if not _absente(e):
            raise
        index = "(vide : aucun disque enregistré)"
    msgs = [{"role": "system", "content": PROMPT + index}, {"role": "user", "content": question}]
    texte = f"Je n'ai pas pu conclure en {MAX_TOURS} tours d'outils ; précise ta demande."
    for _ in range(MAX_TOURS):
        m = llm(msgs, OUTILS)
        appels = m.get("tool_calls") or []
        if not appels:
            texte = m.get("content") or ""
            break
        msgs.append({"role": "assistant", "content": m.get("content"), "tool_calls": appels})
        for a in appels:
            try:
                nom, args = a["function"]["name"], json.loads(a["function"].get("arguments") or "{}")
                if nom == "lire_disque":
                    cle = cle_lecture(args["chemin"], vault_prefix)
                    resultat = _lire_cle(s3, bucket, cle)
                    sources.append(cle[len(vp):])
                elif nom == "chercher":
                    trouve = chercher(s3, bucket, vault_prefix, args["texte"])
                    sources += [t["chemin"] for t in trouve]
                    resultat = json.dumps(trouve, ensure_ascii=False) if trouve else "aucune note trouvée"
                elif nom == "enregistrer_disque":
                    permis = {"artiste", "titre", "format", "annee", "label", "etat", "notes"}
                    rel, resultat = enregistrer(s3, bucket, vault_prefix, now, quiet_minutes,
                                                **{k: v for k, v in args.items() if k in permis})
                    if not resultat.startswith("refusé"):
                        sources.append(rel)
                    resultat = f"{resultat} : {rel}"
                else:
                    resultat = f"erreur : outil inconnu {nom}"
            except ClientError as e:
                resultat = "pas de note à ce chemin" if _absente(e) else f"erreur S3 : {e}"
            except (ValueError, KeyError, TypeError) as e:
                resultat = f"erreur : {e}"
            msgs.append({"role": "tool", "tool_call_id": a.get("id", ""), "content": resultat})
    texte = re.sub(r"(?mi)^[ \t*_]*sources?[ \t*_]*:.*$\n?", "", texte).rstrip()
    if sources:
        texte += "\n\nSources : " + ", ".join(dict.fromkeys(sources))
    return texte
