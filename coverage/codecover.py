"""Is this old code already in a git server? Content-hash coverage against a persistent index.

  python -I codecover.py index forgejo [--url http://forgejo.local]   # token in FORGEJO_TOKEN
  python -I codecover.py index github --owner godefroi                 # uses the gh CLI's login
  python -I codecover.py scan <root> [--depth 2] [--out report.json]
  python -I codecover.py selftest

Index: for every repo, a throwaway blobless clone (commits and trees, no file contents) is read with
`git log --raw` to record every blob id that ever appeared, with its path, plus every commit id and its
git-svn-id. The clone is deleted right after. A repo whose ref tips haven't changed since the last run is
skipped, so re-indexing is cheap.

Scan: every file under <root> is hashed as a git blob in several normalized forms (raw, BOM stripped,
LF / CRLF, svn $Keyword$ expansions collapsed) and looked up in the index. Files are grouped into units:
git clones, topmost svn working copies, and otherwise the folder <depth> levels below <root>.
Git clones also report which local commits the index lacks; svn working copies report the newest
converted revision of their svn path.

Sources under <root> are only read. Git is run against them with object-level commands only, because the
folders may come from untrusted places and a .git/config can carry hooks or fsmonitor commands.
"""
import argparse, hashlib, json, os, re, shutil, sqlite3, stat, subprocess, sys, tempfile, urllib.request
from collections import Counter, defaultdict

DEFAULT_DB = os.path.join(os.environ.get("LOCALAPPDATA") or os.path.expanduser("~/.local/share"), "codecover", "index.db")
GIT_SAFE = ["git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=" + os.devnull, "-c", "safe.directory=*"]
ZERO = "0" * 40
VARIANTS_VERSION = "2"  # bump whenever variants() changes

# Build output, IDE state and VCS metadata: never counted (same rules as consolidation-tools/review_rules.py).
ART_DIRS = {"bin", "obj", "debug", "release", "packages", ".vs", "testresults", "ipch", "node_modules",
            "_upgradereport_files", ".svn", ".git", "_svn"}
ART_DIR_RE = re.compile(r"^_resharper\.|^\.vs$")
ART_EXT = (".pdb", ".suo", ".ncb", ".aps", ".ilk", ".pch", ".obj", ".idb", ".cache", ".vshost.exe", ".tlog",
           ".lastbuildstate", ".sbr", ".bsc", ".ipch", ".sdf", ".opensdf", ".dbmdl", ".jfm", ".user")
ART_NAMES = {"thumbs.db", "desktop.ini", ".ds_store"}


# Folder names that are build output in most projects but sometimes hold real source (e.g. a Nexus
# InterfaceManager/Packages folder of .cs files): source files under them are still counted.
AMBIGUOUS_DIRS = {"packages", "debug", "release"}
SOURCE_EXT = (".cs", ".vb", ".fs", ".c", ".cpp", ".h", ".sql", ".ps1", ".psm1", ".py", ".js", ".ts", ".aspx", ".ascx",
              ".cshtml", ".xslt", ".csproj", ".vbproj", ".sln")


def is_artifact(parts):
    dirs = parts[:-1]
    if any(d in ART_DIRS - AMBIGUOUS_DIRS or ART_DIR_RE.search(d) for d in dirs):
        return True
    if any(d in AMBIGUOUS_DIRS for d in dirs) and not parts[-1].endswith(SOURCE_EXT):
        return True
    return parts[-1] in ART_NAMES or parts[-1].endswith(ART_EXT)


def open_db(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    db = sqlite3.connect(path)
    db.executescript("""
        CREATE TABLE IF NOT EXISTS repos(id INTEGER PRIMARY KEY, source TEXT, name TEXT, url TEXT, fork INT,
                                         tips TEXT, UNIQUE(source, name));
        CREATE TABLE IF NOT EXISTS blobs(sha TEXT, repo INT, path TEXT, name TEXT,
                                         PRIMARY KEY(sha, repo, path)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS blobs_name ON blobs(name);
        CREATE TABLE IF NOT EXISTS commits(sha TEXT, repo INT, svn TEXT, PRIMARY KEY(sha, repo)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS commits_svn ON commits(svn) WHERE svn IS NOT NULL;
        CREATE TABLE IF NOT EXISTS localfiles(path TEXT PRIMARY KEY, size INT, mtime REAL, variants TEXT);
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
    """)
    # cached local hashes are only valid for the variants() that produced them
    if db.execute("SELECT value FROM meta WHERE key='variants'").fetchone() != (VARIANTS_VERSION,):
        db.execute("DELETE FROM localfiles")
        db.execute("INSERT OR REPLACE INTO meta VALUES('variants', ?)", (VARIANTS_VERSION,))
        db.commit()
    return db


# ---------- index ----------

def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", **kw)
    if r.returncode:
        raise RuntimeError(f"{' '.join(cmd[:4])}...: {r.stderr.strip()[:300]}")
    return r.stdout


def forgejo_repos(url):
    token = os.environ.get("FORGEJO_TOKEN")
    if not token:
        sys.exit("FORGEJO_TOKEN is not set")
    out, page = [], 1
    while True:
        req = urllib.request.Request(f"{url}/api/v1/repos/search?limit=50&page={page}",
                                     headers={"Authorization": f"token {token}"})
        data = json.load(urllib.request.urlopen(req))["data"]
        if not data:
            return out
        out += [(r["full_name"], r["clone_url"], int(r["fork"])) for r in data]
        page += 1


def github_repos(owner):
    rows = json.loads(run(["gh", "repo", "list", owner, "--limit", "1000", "--json", "nameWithOwner,url,isFork"]))
    return [(r["nameWithOwner"], r["url"] + ".git", int(r["isFork"])) for r in rows]


def git_auth(source):
    # GitHub private repos authenticate through the gh login; Forgejo through git's own credential helper.
    return ["-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential"] if source == "github" else []


def rmtree(path):
    def onerr(fn, p, _):  # git pack files are read-only on Windows
        os.chmod(p, stat.S_IWRITE); fn(p)
    shutil.rmtree(path, onexc=onerr)


def index_repo(db, source, name, url, fork, force):
    auth = git_auth(source)
    tips = run(["git", *auth, "ls-remote", url])
    tips = "\n".join(sorted(l for l in tips.splitlines() if not l.endswith("^{}")))
    row = db.execute("SELECT id, tips FROM repos WHERE source=? AND name=?", (source, name)).fetchone()
    if row and row[1] == tips and not force:
        return "unchanged"
    if row:
        rid = row[0]
        db.execute("UPDATE repos SET url=?, fork=? WHERE id=?", (url, fork, rid))
    else:
        rid = db.execute("INSERT INTO repos(source, name, url, fork) VALUES(?,?,?,?)", (source, name, url, fork)).lastrowid
    blobs, commits = set(), {}
    if tips:
        tmp = tempfile.mkdtemp(prefix="codecover-")
        try:
            run(["git", *auth, "clone", "-q", "--bare", "--filter=blob:none", url, os.path.join(tmp, "r")])
            log = run(["git", "-C", os.path.join(tmp, "r"), "log", "--all", "--root", "-m", "--raw", "--no-renames",
                       "--no-abbrev", "--format=C %H %(trailers:key=git-svn-id,valueonly,separator=%x20)"])
        finally:
            rmtree(tmp)
        for line in log.splitlines():
            if line.startswith("C "):
                parts = line.split()
                commits[parts[1]] = parts[2] if len(parts) > 2 else None
            elif line.startswith(":"):
                meta, path = line.split("\t", 1)
                _, mode, sha = meta.split()[1:4]
                if sha != ZERO and mode != "160000":  # deletions and submodule links carry no content
                    blobs.add((sha, path))
    db.execute("DELETE FROM blobs WHERE repo=?", (rid,))
    db.execute("DELETE FROM commits WHERE repo=?", (rid,))
    db.executemany("INSERT INTO blobs VALUES(?,?,?,?)", ((s, rid, p, p.rsplit("/", 1)[-1].lower()) for s, p in blobs))
    db.executemany("INSERT INTO commits VALUES(?,?,?)", ((s, rid, v) for s, v in commits.items()))
    db.execute("UPDATE repos SET tips=? WHERE id=?", (tips, rid))
    db.commit()
    return f"{len(commits)} commits, {len(blobs)} blob/path pairs"


def cmd_index(a):
    db = open_db(a.db)
    repos = forgejo_repos(a.url.rstrip("/")) if a.source == "forgejo" else github_repos(a.owner)
    seen = set()
    for name, url, fork in repos:
        seen.add(name)
        try:
            print(f"{name}: {index_repo(db, a.source, name, url, fork, a.force)}", flush=True)
        except RuntimeError as e:
            print(f"{name}: FAILED {e}", flush=True)
    gone = [(i, n) for i, n in db.execute("SELECT id, name FROM repos WHERE source=?", (a.source,)) if n not in seen]
    for rid, name in gone:  # repo deleted or renamed on the server: drop it so nothing claims coverage from it
        for t in ("blobs", "commits"):
            db.execute(f"DELETE FROM {t} WHERE repo=?", (rid,))
        db.execute("DELETE FROM repos WHERE id=?", (rid,))
        print(f"{name}: removed (no longer on {a.source})")
    db.commit()


# ---------- scan ----------

KW = re.compile(rb"\$(Id|Rev|Revision|LastChangedRevision|Date|LastChangedDate|Author|LastChangedBy|HeadURL|URL|Header)(:[^$\r\n]*)?\$")
BOM = b"\xef\xbb\xbf"


def blob_id(d):
    return hashlib.sha1(b"blob %d\0" % len(d) + d).hexdigest()


def utf16_text(d):
    """UTF-16 text (SSMS scripts, .rc files) decoded to UTF-8 bytes; None if d isn't BOM-marked UTF-16."""
    if d[:2] in (b"\xff\xfe", b"\xfe\xff"):
        try:
            return d.decode("utf-16").encode("utf-8")
        except UnicodeDecodeError:
            return None
    return None


def variants(d):
    out = {blob_id(d)}
    u = utf16_text(d)
    if u is not None:
        return out | variants(u)
    if b"\0" in d[:8000]:  # binary: only exact bytes are meaningful
        return out
    try:  # the same text saved as UTF-16 LE with BOM, as SSMS does
        t = d[3:] if d.startswith(BOM) else d
        out |= {blob_id(b"\xff\xfe" + t.decode("utf-8").encode("utf-16-le")),
                blob_id(b"\xff\xfe" + t.decode("utf-8").replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-16-le"))}
    except UnicodeDecodeError:
        pass
    for base in {d, d[3:] if d.startswith(BOM) else BOM + d}:
        lf = base.replace(b"\r\n", b"\n")
        for t in (lf, KW.sub(lambda m: b"$" + m.group(1) + b"$", lf)):
            out |= {blob_id(t), blob_id(t.replace(b"\n", b"\r\n"))}
    return out


def find_units(root):
    """Git clones and topmost svn working copies under root, as relative paths with '/'."""
    git, svn = [], []
    for d, dirs, _ in os.walk(root):
        rel = os.path.relpath(d, root).replace("\\", "/")
        rel = "" if rel == "." else rel
        if ".git" in dirs:
            git.append(rel)
        # pre-1.7 working copies have .svn in every folder; os.walk is top-down, so the first one seen is the top
        if ".svn" in dirs and not any(rel.startswith(s + "/") for s in svn):
            svn.append(rel)
        dirs[:] = [x for x in dirs if x not in (".git", ".svn")]
    return git, svn


def unit_of(rel, vcs, depth):
    best = max((u for u in vcs if rel.startswith(u + "/")), key=len, default=None)
    if best is not None:
        return best
    parts = rel.split("/")[:-1]
    return "/".join(parts[:depth]) or "."


def git_unit_info(db, path):
    g = GIT_SAFE + ["--git-dir", os.path.join(path, ".git")]
    try:
        # %(*objectname) is the commit an annotated tag points to; empty for branches and lightweight tags
        refs = [l.split(" ", 1) for l in run(g + ["for-each-ref", "--format=%(if)%(*objectname)%(then)%(*objectname)%(else)%(objectname)%(end) %(refname)"]).splitlines()]
        local = run(g + ["rev-list", "--all"]).split()
    except RuntimeError as e:
        return {"error": str(e)}
    def have(sha):
        return db.execute("SELECT 1 FROM commits WHERE sha=?", (sha,)).fetchone() is not None
    missing = [c for c in local if not have(c)]
    shown = []
    if missing:
        log = run(g + ["log", "--no-walk=unsorted", "--format=%H %ad %an: %s", "--date=short", *missing[:20]])
        shown = log.splitlines()
    repos = Counter(r for c in local[:200] for (r,) in db.execute(
        "SELECT name FROM commits JOIN repos ON repos.id=repo WHERE sha=?", (c,)))
    return {"refs": len(refs), "refs_missing": [r for s, r in refs if not have(s)],
            "commits": len(local), "commits_missing": len(missing), "missing_commits": shown,
            "commit_repos": repos.most_common(3)}


def svn_unit_info(db, path):
    sv = os.path.join(path, ".svn")
    relpath = rev = url = None
    try:
        if os.path.exists(os.path.join(sv, "wc.db")):
            w = sqlite3.connect(f"file:{os.path.join(sv, 'wc.db')}?mode=ro", uri=True)
            relpath, rev, url = w.execute(
                "SELECT n.repos_path, n.revision, r.root FROM nodes n JOIN repository r ON r.id=n.repos_id "
                "WHERE n.local_relpath='' AND n.op_depth=0").fetchone()
            w.close()
        else:
            text = open(os.path.join(sv, "entries"), encoding="utf-8", errors="replace").read()
            if text.lstrip().startswith("<"):  # svn <= 1.3: XML; the entry with name="" is the folder itself
                m = re.search(r'<entry\b(?=[^>]*\bname="")[^>]*>', text, re.S)
                attr = dict(re.findall(r'(\w+)="([^"]*)"', m.group(0))) if m else {}
                rev, full, root = int(attr.get("revision", 0)) or None, attr.get("url"), attr.get("repos", "")
            else:  # svn 1.4-1.6: lines 4/5/6 = revision, url, repository root (root may be blank)
                e = text.split("\n")
                rev, full, root = int(e[3]), e[4], e[5]
            if not full:
                return {"error": "no url in entries"}
            url, relpath = (root, full[len(root):].lstrip("/")) if root else (full, None)
    except (OSError, sqlite3.Error, IndexError, ValueError, TypeError) as e:
        return {"error": str(e)}
    from urllib.parse import quote, unquote, urlsplit
    full_url = f"{url}/{relpath}" if relpath is not None else url
    # Root servers seen so far: http://svn/repos, marduk:88/svn, file:///w/svn/medicity. Without a known
    # repository root, svn_converted tries the longest suffix of the url path that some conversion has.
    comps = [quote(unquote(c)) for c in (relpath.split("/") if relpath is not None else urlsplit(full_url).path.split("/")) if c]
    externals = []
    if os.path.exists(os.path.join(sv, "wc.db")):
        # svn:externals pull other svn paths into the checkout; they are often never converted on their own
        w = sqlite3.connect(f"file:{os.path.join(sv, 'wc.db')}?mode=ro", uri=True)
        for local, ext in w.execute("SELECT local_relpath, def_repos_relpath FROM externals WHERE kind='dir'"):
            externals.append({"local": local, "svn_path": ext, "converted": svn_converted(db, ext.split("/"), True)})
        w.close()
    return {"url": full_url, "revision": rev, "converted": svn_converted(db, comps, relpath is not None),
            "externals": externals}


def svn_converted(db, comps, exact):
    """Newest git-svn-converted revision of an svn path (list of url-quoted components), matched on path because
    the url's root differs between conversions. When not exact, also try shorter suffixes of the path."""
    from urllib.parse import quote, unquote
    comps = [quote(unquote(c)) for c in comps]
    for i in range(1 if exact else max(len(comps) - 1, 1)):
        cand, best = "/".join(comps[i:]), None
        for name, svn in db.execute("SELECT name, svn FROM commits JOIN repos ON repos.id=repo WHERE svn LIKE ?",
                                    (f"%/{cand}@%",)):
            r = int(svn.split()[0].rsplit("@", 1)[1])
            if best is None or r > best["max_revision"]:
                best = {"repo": name, "max_revision": r, "path": cand}
        if best:
            return best
    return None


def candidates(db, rel, limit=3):
    """Indexed blobs with the same file name, best path-suffix match first: likely other versions of this file."""
    name = rel.rsplit("/", 1)[-1].lower()
    mine = rel.lower().split("/")[::-1]
    rows = db.execute("SELECT r.source, r.name, b.path, b.sha FROM blobs b JOIN repos r ON r.id=b.repo WHERE b.name=?",
                      (name,)).fetchall()
    def suffix(p):
        n = 0
        for x, y in zip(mine, p.lower().split("/")[::-1]):
            if x != y:
                break
            n += 1
        return n
    rows.sort(key=lambda r: -suffix(r[2]))
    seen, out = set(), []
    for src, repo, path, sha in rows:  # one candidate per distinct content
        if sha not in seen:
            seen.add(sha); out.append({"source": src, "repo": repo, "path": path, "sha": sha})
        if len(out) == limit * 4:
            break
    return out


_tokens = {}


def fetch_blob(src, repo, sha, url):
    """One blob's bytes through the server's API (no clone)."""
    import base64
    if src == "github":
        if "github" not in _tokens:
            _tokens["github"] = run(["gh", "auth", "token"]).strip()
        api, auth = f"https://api.github.com/repos/{repo}/git/blobs/{sha}", f"Bearer {_tokens['github']}"
    else:
        base = url.split("/", 3)
        api, auth = f"{base[0]}//{base[2]}/api/v1/repos/{repo}/git/blobs/{sha}", f"token {os.environ['FORGEJO_TOKEN']}"
    req = urllib.request.Request(api, headers={"Authorization": auth})
    return base64.b64decode(json.load(urllib.request.urlopen(req))["content"])


def lines(d):
    d = utf16_text(d) or d
    d = d[3:] if d.startswith(BOM) else d
    return [l.strip() for l in KW.sub(lambda m: b"$" + m.group(1) + b"$", d).replace(b"\r\n", b"\n").split(b"\n") if l.strip()]


def classify_uncovered(db, root, units):
    """binary / near (>=95% same lines as a version in a repo) / modified (>=50%) / new. Ratios are cached."""
    import difflib
    db.execute("CREATE TABLE IF NOT EXISTS similar(local TEXT, blob TEXT, ratio REAL, PRIMARY KEY(local, blob)) WITHOUT ROWID")
    urls = {(s, n): u for s, n, u in db.execute("SELECT source, name, url FROM repos")}
    for u in units.values():
        for f in u["uncovered"]:
            data = open(os.path.join(root, f["path"]), "rb").read()
            if b"\0" in data[:8000] and utf16_text(data) is None:
                f["class"] = "binary"
                continue
            key, mine, best = blob_id(data), None, (0.0, None)
            for c in f["candidates"]:
                row = db.execute("SELECT ratio FROM similar WHERE local=? AND blob=?", (key, c["sha"])).fetchone()
                if row:
                    r = row[0]
                else:
                    try:
                        theirs = fetch_blob(c["source"], c["repo"], c["sha"], urls[(c["source"], c["repo"])])
                    except Exception as e:  # network/API trouble: leave this candidate unscored
                        print(f"fetch {c['repo']}:{c['path']}: {e}", file=sys.stderr)
                        continue
                    mine = mine or lines(data)
                    r = difflib.SequenceMatcher(None, mine, lines(theirs), autojunk=False).ratio()
                    db.execute("INSERT OR REPLACE INTO similar VALUES(?,?,?)", (key, c["sha"], r))
                if r > best[0]:
                    best = (r, c)
                if r >= 0.999:
                    break
            db.commit()
            f["best_match"] = {"ratio": round(best[0], 3), **best[1]} if best[1] else None
            f["class"] = "near" if best[0] >= 0.95 else "modified" if best[0] >= 0.5 else "new"
            f["candidates"] = f["candidates"][:3]


def cmd_scan(a):
    db = open_db(a.db)
    root = os.path.abspath(a.root)
    git, svn = find_units(root)
    vcs = git + svn
    units = defaultdict(lambda: {"files": 0, "covered": 0, "repos": Counter(), "uncovered": [], "skipped": Counter()})
    n = 0
    for d, dirs, fs in os.walk(root):
        dirs[:] = [x for x in dirs if x not in (".git", ".svn", "_svn")]
        for fn in fs:
            full = os.path.join(d, fn)
            rel = os.path.relpath(full, root).replace("\\", "/")
            if is_artifact(rel.lower().split("/")):
                # counted by extension so source hiding in a folder named bin/Release/packages is visible
                units[unit_of(rel, vcs, a.depth)]["skipped"][os.path.splitext(fn)[1].lower() or "(none)"] += 1
                continue
            try:
                st = os.stat(full)
                row = db.execute("SELECT size, mtime, variants FROM localfiles WHERE path=?", (full,)).fetchone()
                if row and row[0] == st.st_size and row[1] == st.st_mtime:
                    vs = json.loads(row[2])
                else:
                    with open(full, "rb") as f:
                        vs = sorted(variants(f.read()))
                    db.execute("INSERT OR REPLACE INTO localfiles VALUES(?,?,?,?)", (full, st.st_size, st.st_mtime, json.dumps(vs)))
            except OSError as e:
                print(f"skip {rel}: {e}", file=sys.stderr)
                continue
            u = units[unit_of(rel, vcs, a.depth)]
            u["files"] += 1
            q = ",".join("?" * len(vs))
            hits = {name for (name,) in db.execute(
                f"SELECT DISTINCT r.name FROM blobs b JOIN repos r ON r.id=b.repo WHERE b.sha IN ({q})", vs)}
            if hits:
                u["covered"] += 1
                u["repos"].update(hits)
            else:
                u["uncovered"].append({"path": rel, "size": st.st_size, "candidates": candidates(db, rel)})
            n += 1
            if n % 2000 == 0:
                db.commit()
                print(f"{n} files", file=sys.stderr, flush=True)
    db.commit()
    if not a.no_similar:
        classify_uncovered(db, root, units)
    forks = {name for (name,) in db.execute("SELECT name FROM repos WHERE fork=1")}
    out = []
    for key in sorted(units):
        u = units[key]
        r = {"unit": key, "kind": "git" if key in git else "svn" if key in svn else "plain",
             "files": u["files"], "covered": u["covered"],
             "pct": round(100 * u["covered"] / u["files"], 1) if u["files"] else 100.0,
             "best": [(name + (" (fork)" if name in forks else ""), c) for name, c in u["repos"].most_common(3)],
             "uncovered": u["uncovered"], "skipped": dict(u["skipped"].most_common())}
        if r["kind"] == "git":
            r["git"] = git_unit_info(db, os.path.join(root, key))
        elif r["kind"] == "svn":
            r["svn"] = svn_unit_info(db, os.path.join(root, key))
        out.append(r)
    json.dump({"root": root, "units": out}, open(a.out, "w", encoding="utf-8"), indent=1)
    print(f"{'unit':<60} {'kind':<5} {'files':>6} {'cov%':>6}  best")
    for r in out:
        print(f"{r['unit'][:60]:<60} {r['kind']:<5} {r['files']:>6} {r['pct']:>6}  {r['best'][0][0] if r['best'] else '-'}")
    print(f"\n{sum(r['files'] for r in out)} files, {sum(len(r['uncovered']) for r in out)} uncovered; details in {a.out}")


def cmd_selftest(_):
    assert blob_id(b"hello\n") == "ce013625030ba8dba906f756967f9e9ca394464a"  # git hash-object of "hello\n"
    assert blob_id(b"a\nb\n") in variants(b"a\r\nb\r\n")
    assert blob_id(b"a\nb\n") in variants(BOM + b"a\r\nb\r\n")
    assert blob_id(b"x $Id$\n") in variants(b"x $Id: foo.cs 123 2008-01-01 bob $\r\n")
    assert variants(b"\0\r\n") == {blob_id(b"\0\r\n")}
    assert blob_id(b"\xff\xfea\x00\r\x00\n\x00") in variants(b"a\n")  # UTF-16 copy in the repo
    assert blob_id(b"a\n") in variants(b"\xff\xfea\x00\r\x00\n\x00")  # UTF-16 copy on disk
    assert unit_of("a/b/c/d.cs", ["a/b"], 2) == "a/b" and unit_of("a/x/y/z.cs", ["a/b"], 2) == "a/x"
    assert unit_of("top.ps1", [], 2) == "."
    assert is_artifact(["p", "bin", "x.dll"]) and not is_artifact(["p", "binary.cs"])
    assert not is_artifact(["p", "packages", "x.cs"]) and is_artifact(["p", "packages", "x.dll"])
    assert is_artifact(["p", "obj", "x.cs"])
    print("ok")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--db", default=DEFAULT_DB)
    sub = p.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("index"); i.add_argument("source", choices=["forgejo", "github"])
    i.add_argument("--url", default="http://forgejo.local"); i.add_argument("--owner", default="godefroi")
    i.add_argument("--force", action="store_true", help="re-read repos even if their tips are unchanged")
    s = sub.add_parser("scan"); s.add_argument("root"); s.add_argument("--depth", type=int, default=2)
    s.add_argument("--out", default="coverage.json")
    s.add_argument("--no-similar", action="store_true", help="skip fetching same-named blobs to score uncovered files")
    sub.add_parser("selftest")
    a = p.parse_args()
    {"index": cmd_index, "scan": cmd_scan, "selftest": cmd_selftest}[a.cmd](a)


if __name__ == "__main__":
    main()
