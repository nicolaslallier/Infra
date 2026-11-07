use crate::config::Config;
use crate::portainer::{Client, Stack};
use crate::{catalog, github, validate};
use anyhow::{anyhow, bail, Context, Result};
use std::path::PathBuf;

const COMPOSE: &str = include_str!("../../session.compose.yml");

pub fn stack_env(
    cfg: &Config,
    name: &str,
    repo: &str,
    token: &str,
    plugins: &[String],
    pubkey: &str,
) -> Vec<(String, String)> {
    [
        ("SESSION", name.to_string()),
        ("REPO_URL", format!("https://github.com/{repo}")),
        ("GH_TOKEN", token.to_string()),
        ("PLUGINS", plugins.join(",")),
        ("MARKETPLACES", cfg.catalogs.join(",")),
        ("SSH_PUBKEY", pubkey.to_string()),
        ("S3_SECRET_KEY", cfg.s3_secret_key.clone()),
        ("MEM_LIMIT", cfg.mem_limit.clone()),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v))
    .collect()
}

pub fn check_cap(active: usize, max: usize) -> Result<(), String> {
    if active >= max {
        Err(format!(
            "trop de sessions actives ({active}/{max}): arrête-en une (devbox stop)"
        ))
    } else {
        Ok(())
    }
}

pub fn ssh_config_entry(cfg: &Config, name: &str) -> String {
    format!(
        "# devbox: {name}\nHost dev-{name}\n  HostName dev-{name}\n  User dev\n  Port 2222\n  ProxyJump jump@{}:{}\n# devbox-end: {name}\n",
        cfg.ssh_host, cfg.ssh_port
    )
}

pub fn remove_ssh_block(existing: &str, name: &str) -> String {
    let (start, end) = (format!("# devbox: {name}"), format!("# devbox-end: {name}"));
    let mut skip = false;
    let mut out = String::new();
    for l in existing.split_inclusive('\n') {
        if l.trim_end() == start {
            skip = true;
        }
        if !skip {
            out.push_str(l);
        }
        if skip && l.trim_end() == end {
            skip = false;
        }
    }
    // No end marker: never drop to EOF, leave the file as it was.
    if skip {
        return existing.to_string();
    }
    out
}

pub fn upsert_ssh_block(existing: &str, entry: &str, name: &str) -> String {
    let mut s = remove_ssh_block(existing, name);
    if !s.is_empty() && !s.ends_with('\n') {
        s.push('\n');
    }
    s + entry
}

pub fn pubkey_line(content: &str) -> Result<String, String> {
    if content.contains("PRIVATE KEY") {
        return Err("le fichier contient une clé PRIVÉE: indique la clé publique (.pub)".into());
    }
    let l = content
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .ok_or("clé publique vide")?;
    if ["ssh-", "ecdsa-", "sk-"].iter().any(|p| l.starts_with(p)) {
        Ok(l.to_string())
    } else {
        Err("ce n'est pas une clé publique SSH (ssh-/ecdsa-/sk-)".into())
    }
}

pub fn plan_create(name: &str, stacks: &[Stack], max: usize) -> Result<(), String> {
    validate::session_name(name)?;
    if stacks.iter().any(|s| s.name == format!("dev-{name}")) {
        return Err(format!("la session '{name}' existe déjà"));
    }
    check_cap(running(stacks), max)
}

pub fn plugin_id_ok(id: &str) -> bool {
    matches!(id.split_once('@'), Some((p, m)) if catalog::safe_name(p) && catalog::safe_name(m))
}

// Missing file means empty; any other error must not turn into a wipe.
pub fn read_or_empty(p: &std::path::Path) -> std::io::Result<String> {
    match std::fs::read_to_string(p) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        r => r,
    }
}

fn running(stacks: &[Stack]) -> usize {
    stacks
        .iter()
        .filter(|s| s.name.starts_with("dev-") && s.running)
        .count()
}

fn find<'a>(stacks: &'a [Stack], name: &str) -> Result<&'a Stack> {
    stacks
        .iter()
        .find(|s| s.name == format!("dev-{name}"))
        .ok_or_else(|| anyhow!("session '{name}' introuvable"))
}

fn ssh_config_path() -> Result<PathBuf> {
    let home = directories::BaseDirs::new().context("dossier personnel introuvable")?;
    Ok(home.home_dir().join(".ssh").join("config"))
}

// Returns whether the file content changed. Atomic: temp file, then rename.
fn edit_ssh_config(f: impl FnOnce(&str) -> String) -> Result<bool> {
    let p = ssh_config_path()?;
    std::fs::create_dir_all(p.parent().unwrap())?;
    let cur = read_or_empty(&p).with_context(|| format!("lecture de {}", p.display()))?;
    let new = f(&cur);
    if new == cur {
        return Ok(false);
    }
    let tmp = p.with_extension("devbox-tmp");
    std::fs::write(&tmp, &new).with_context(|| format!("écriture de {}", tmp.display()))?;
    if std::fs::rename(&tmp, &p).is_err() {
        // Windows: rename onto an existing file can fail.
        let _ = std::fs::remove_file(&p);
        std::fs::rename(&tmp, &p).with_context(|| format!("remplacement de {}", p.display()))?;
    }
    Ok(true)
}

pub fn finish_create(
    client: &Client,
    cfg: &Config,
    name: &str,
    slug: &str,
    token: &str,
    plugins: &[String],
    pubkey: &str,
) -> Result<()> {
    let env = stack_env(cfg, name, slug, token, plugins, pubkey);
    client
        .create_stack(&format!("dev-{name}"), COMPOSE, &env)
        .map_err(|e| anyhow!(e))?;
    let entry = ssh_config_entry(cfg, name);
    if let Err(e) = edit_ssh_config(|c| upsert_ssh_block(c, &entry, name)) {
        bail!("session créée mais ~/.ssh/config non mis à jour ({e}). Ajoute ce bloc à la main:\n{entry}");
    }
    println!("Session '{name}' créée.\n  ssh dev-{name}\nAu premier lancement: tape `claude` puis connecte-toi avec le lien d'abonnement.");
    Ok(())
}

pub fn create(cfg: &Config, name: &str, repo: Option<String>, plugins: Vec<String>) -> Result<()> {
    validate::session_name(name).map_err(|e| anyhow!(e))?; // before any network call
    if let Some(bad) = plugins.iter().find(|p| !plugin_id_ok(p)) {
        bail!("plugin invalide '{bad}' (attendu: nom@marketplace, [A-Za-z0-9._-])");
    }
    let client = Client::new(cfg).map_err(|e| anyhow!(e))?;
    let stacks = client.list_stacks().map_err(|e| anyhow!(e))?;
    // ponytail: check-then-act; concurrent invocations can exceed the cap by one (single owner).
    plan_create(name, &stacks, cfg.max_active).map_err(|e| anyhow!(e))?;

    let pubkey = pubkey_line(
        &std::fs::read_to_string(&cfg.pubkey_path)
            .with_context(|| format!("lecture de {}", cfg.pubkey_path.display()))?,
    )
    .map_err(|e| anyhow!(e))?;
    let repo = match repo {
        Some(r) => r,
        None => dialoguer::Input::<String>::new()
            .with_prompt("Dépôt GitHub (URL ou owner/nom)")
            .interact_text()?,
    };
    let slug = validate::repo_slug(&repo).map_err(|e| anyhow!(e))?;
    let token = match std::env::var("DEVBOX_GH_TOKEN") {
        Ok(t) if !t.is_empty() => t,
        _ => dialoguer::Password::new()
            .with_prompt("Jeton GitHub")
            .interact()?,
    };
    if !github::main_is_protected(&slug, &token).map_err(|e| anyhow!(e))? {
        bail!("active la protection de `main` d'abord (dépôt {slug})");
    }
    let plugins = if plugins.is_empty() {
        pick_plugins(cfg)?
    } else {
        plugins
    };

    finish_create(&client, cfg, name, &slug, &token, &plugins, &pubkey)
}

fn pick_plugins(cfg: &Config) -> Result<Vec<String>> {
    let all = catalog::fetch_all(&cfg.catalogs).map_err(|e| anyhow!(e))?;
    if all.is_empty() {
        return Ok(vec![]);
    }
    let labels: Vec<String> = all
        .iter()
        .map(|p| format!("{} - {}", p.id, p.description))
        .collect();
    let sel = dialoguer::MultiSelect::new()
        .with_prompt("Plugins (espace pour cocher)")
        .items(&labels)
        .interact()?;
    let ids: Vec<String> = sel.into_iter().map(|i| all[i].id.clone()).collect();
    if let Some(bad) = ids.iter().find(|p| !plugin_id_ok(p)) {
        bail!("plugin invalide '{bad}' dans le catalogue");
    }
    Ok(ids)
}

pub fn list(cfg: &Config) -> Result<()> {
    for s in Client::new(cfg)
        .map_err(|e| anyhow!(e))?
        .list_stacks()
        .map_err(|e| anyhow!(e))?
    {
        if let Some(n) = s.name.strip_prefix("dev-") {
            println!("{n}\t{}", if s.running { "en cours" } else { "arrêtée" });
        }
    }
    Ok(())
}

pub fn stop(cfg: &Config, name: &str) -> Result<()> {
    validate::session_name(name).map_err(|e| anyhow!(e))?;
    let c = Client::new(cfg).map_err(|e| anyhow!(e))?;
    let id = find(&c.list_stacks().map_err(|e| anyhow!(e))?, name)?.id;
    c.stop(id).map_err(|e| anyhow!(e))?; // synchronous on Portainer's side
    println!("Session '{name}' arrêtée.");
    Ok(())
}

pub fn resume(cfg: &Config, name: &str) -> Result<()> {
    validate::session_name(name).map_err(|e| anyhow!(e))?;
    let c = Client::new(cfg).map_err(|e| anyhow!(e))?;
    let stacks = c.list_stacks().map_err(|e| anyhow!(e))?;
    let s = find(&stacks, name)?;
    if !s.running {
        check_cap(running(&stacks), cfg.max_active).map_err(|e| anyhow!(e))?;
        c.start(s.id).map_err(|e| anyhow!(e))?;
    }
    println!("Session '{name}' en cours: ssh dev-{name}");
    Ok(())
}

pub fn delete(cfg: &Config, name: &str, yes: bool, purge: bool) -> Result<()> {
    validate::session_name(name).map_err(|e| anyhow!(e))?;
    let c = Client::new(cfg).map_err(|e| anyhow!(e))?;
    let id = find(&c.list_stacks().map_err(|e| anyhow!(e))?, name)?.id;
    if !yes
        && !dialoguer::Confirm::new()
            .with_prompt(format!(
                "Supprimer la session '{name}' et son volume /work?"
            ))
            .default(false)
            .interact()?
    {
        bail!("annulé");
    }
    if let Err(e) = c.delete(id) {
        // Volume and ssh entry stay untouched until the stack is really gone.
        bail!("{e}. La pile s'arrête peut-être encore côté serveur (délai de grâce 120 s): relance `devbox delete {name}`");
    }
    if let Err(e) = c.delete_volume(&format!("dev-{name}-work")) {
        if !e.contains("404") {
            eprintln!("avertissement: volume non supprimé: {e}");
        }
    }
    for host in [format!("[dev-{name}]:2222"), format!("dev-{name}")] {
        let _ = std::process::Command::new("ssh-keygen")
            .args(["-R", &host])
            .output();
    }
    match edit_ssh_config(|cur| remove_ssh_block(cur, name)) {
        Ok(true) => {}
        Ok(false) => eprintln!("avertissement: bloc `# devbox: {name}` absent ou non terminé dans ~/.ssh/config, laissé tel quel"),
        Err(e) => eprintln!("avertissement: ~/.ssh/config non modifié: {e}"),
    }
    println!("Session '{name}' supprimée (l'état sauvegardé dans le bucket est conservé).");
    if purge {
        println!("--purge n'est pas automatisé. Pour vider le bucket: rclone purge devbox:devbox/{name} (avec les identifiants S3 devbox)");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> Config {
        Config::parse("portainer_url=\"http://127.0.0.1:1\"\napi_key=\"K\"\nendpoint_id=2\nssh_host=\"192.168.2.10\"\nssh_port=2200\npubkey_path=\"/p\"\ns3_secret_key=\"S3\"\ncatalogs=[\"a/b\",\"c/d\"]").unwrap()
    }
    fn st(n: &str, running: bool) -> Stack {
        Stack {
            id: 1,
            name: n.into(),
            running,
        }
    }

    #[test]
    fn env_has_exactly_eight() {
        let e = stack_env(
            &cfg(),
            "jarvis",
            "o/r",
            "tok",
            &["p@m".into(), "q@m".into()],
            "ssh-ed25519 AAA",
        );
        let want = [
            ("SESSION", "jarvis"),
            ("REPO_URL", "https://github.com/o/r"),
            ("GH_TOKEN", "tok"),
            ("PLUGINS", "p@m,q@m"),
            ("MARKETPLACES", "a/b,c/d"),
            ("SSH_PUBKEY", "ssh-ed25519 AAA"),
            ("S3_SECRET_KEY", "S3"),
            ("MEM_LIMIT", "1536m"),
        ];
        let want: Vec<(String, String)> = want
            .iter()
            .map(|(a, b)| (a.to_string(), b.to_string()))
            .collect();
        assert_eq!(e, want);
    }

    #[test]
    fn cap() {
        assert!(check_cap(3, 4).is_ok());
        let e = check_cap(4, 4).unwrap_err();
        assert!(e.contains("4/4"), "{e}");
    }

    #[test]
    fn ssh_entry_exact() {
        assert_eq!(
            ssh_config_entry(&cfg(), "jarvis"),
            "# devbox: jarvis\nHost dev-jarvis\n  HostName dev-jarvis\n  User dev\n  Port 2222\n  ProxyJump jump@192.168.2.10:2200\n# devbox-end: jarvis\n"
        );
    }

    #[test]
    fn ssh_upsert_and_remove() {
        let e = ssh_config_entry(&cfg(), "jarvis");
        let other = "Host x\n  User y\n";
        let once = upsert_ssh_block(other, &e, "jarvis");
        assert_eq!(upsert_ssh_block(&once, &e, "jarvis"), once);
        assert_eq!(once.matches("Host dev-jarvis").count(), 1);
        assert!(once.starts_with(other));
        assert_eq!(remove_ssh_block(&once, "jarvis"), other);
        assert_eq!(upsert_ssh_block("", &e, "jarvis"), e);
    }

    #[test]
    fn pubkey() {
        assert_eq!(
            pubkey_line("\n ssh-ed25519 AAA me\n").unwrap(),
            "ssh-ed25519 AAA me"
        );
        assert!(pubkey_line("-----BEGIN OPENSSH PRIVATE KEY-----\nssh-ed25519 x").is_err());
        assert!(pubkey_line("hello world").is_err());
        assert!(pubkey_line("").is_err());
        assert!(pubkey_line("ecdsa-sha2-nistp256 AAA").is_ok());
        assert!(pubkey_line("sk-ssh-ed25519@openssh.com AAA").is_ok());
    }

    #[test]
    fn plan_rules() {
        let s = [
            st("dev-a", true),
            st("dev-b", true),
            st("dev-c", false),
            st("other", true),
        ];
        assert!(plan_create("Bad_Name", &s, 4)
            .unwrap_err()
            .contains("invalide"));
        assert!(plan_create("aaa", &[st("dev-aaa", false)], 4)
            .unwrap_err()
            .contains("existe"));
        assert!(plan_create("new", &s, 4).is_ok());
        let e = plan_create("new", &s, 2).unwrap_err();
        assert!(e.contains("2/2"), "{e}");
    }

    #[test]
    fn bad_name_fails_before_network() {
        // portainer_url points at a closed port: a network call would say "injoignable".
        let e = create(&cfg(), "Bad_Name", None, vec![])
            .unwrap_err()
            .to_string();
        assert!(e.contains("invalide"), "{e}");
    }

    #[test]
    fn unterminated_block_left_alone() {
        let t = "Host a\n  User x\n# devbox: foo\nHost dev-foo\n  Port 1\nHost b\n  User y\n";
        assert_eq!(remove_ssh_block(t, "foo"), t);
        let ok = "Host a\n# devbox: foo\nHost dev-foo\n# devbox-end: foo\nHost b\n";
        assert_eq!(remove_ssh_block(ok, "foo"), "Host a\nHost b\n");
    }

    #[test]
    fn plugin_ids() {
        for bad in ["a,b@m", "p@m;x", "p", "@m", "p@", "a@b@c", "p@m "] {
            assert!(!plugin_id_ok(bad), "{bad}");
        }
        assert!(plugin_id_ok("p@m") && plugin_id_ok("my.plug-in_1@official-mkt"));
    }

    #[test]
    fn read_or_empty_only_for_missing() {
        let d = std::env::temp_dir().join(format!("devbox-t-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        assert_eq!(read_or_empty(&d.join("nope")).unwrap(), "");
        std::fs::write(d.join("bad"), [0xff, 0xfe]).unwrap();
        assert!(read_or_empty(&d.join("bad")).is_err());
        assert!(read_or_empty(&d).is_err()); // a directory: not NotFound
        std::fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn failing_create_leaks_no_secret() {
        use std::io::{Read, Write};
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let mut c = cfg();
        c.portainer_url = format!("http://{}", l.local_addr().unwrap());
        let h = std::thread::spawn(move || {
            let (mut s, _) = l.accept().unwrap();
            let mut b = [0u8; 8192];
            let _ = s.read(&mut b);
            let r = "{\"message\":\"boom\"}";
            let _ = write!(
                s,
                "HTTP/1.1 500 X\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{r}",
                r.len()
            );
        });
        let e = finish_create(
            &Client::build(&c, true).unwrap(),
            &c,
            "aaa",
            "o/r",
            "ghp_TOKEN",
            &[],
            "ssh-ed25519 AAA",
        )
        .unwrap_err();
        h.join().unwrap();
        let e = format!("{e} {e:?}");
        assert!(e.contains("500"), "{e}");
        assert!(
            !e.contains("ghp_TOKEN") && !e.contains("S3") && !e.contains("\"K\""),
            "{e}"
        );
    }
}
