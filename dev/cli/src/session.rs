//! Pure pieces of the session commands: stack env, the cap, the SSH config.
use crate::config::Config;

/// Everything the stack env needs that is not in the config.
pub struct NewSession<'a> {
    pub name: &'a str,
    /// `owner/repo`
    pub repo: &'a str,
    pub token: &'a str,
    pub plugins: &'a [String],
    /// Comma-joined, from `pubkeys`.
    pub pubkeys: &'a str,
    /// This session's own S3 secret (identity `devbox-<name>`).
    pub s3_secret: &'a str,
}

/// The stack env dev/session.compose.yml reads.
pub fn stack_env(cfg: &Config, s: &NewSession) -> Vec<(String, String)> {
    [
        ("SESSION", s.name.to_string()),
        ("REPO_URL", format!("https://github.com/{}", s.repo)),
        ("GH_TOKEN", s.token.to_string()),
        ("MARKETPLACES", cfg.catalogs.join(",")),
        ("PLUGINS", s.plugins.join(",")),
        ("SSH_PUBKEYS", s.pubkeys.to_string()),
        ("S3_ACCESS_KEY", format!("devbox-{}", s.name)),
        ("S3_SECRET_KEY", s.s3_secret.to_string()),
        ("MEM_LIMIT", cfg.mem_limit.clone()),
        ("CPUS", cfg.cpus.clone()),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v))
    .collect()
}

/// The owner's public keys, comma-joined for SSH_PUBKEYS: the creating
/// machine's plus `extra_pubkeys`. A key holding a comma or a newline would
/// split into garbage, so it is refused.
pub fn pubkeys(primary: &str, extra: &[String]) -> Result<String, String> {
    let keys: Vec<&str> = std::iter::once(primary.trim()).chain(extra.iter().map(|k| k.trim())).collect();
    for k in &keys {
        if k.is_empty() || k.contains(',') || k.contains('\n') {
            return Err(format!("unusable public key {k:?}: empty, or holds a comma or a line break"));
        }
    }
    Ok(keys.join(","))
}

/// Refuses a create/resume that would exceed `max` running sessions.
pub fn check_cap(active: usize, max: usize) -> Result<(), String> {
    if active < max {
        Ok(())
    } else {
        Err(format!("{active} sessions running, the cap is {max} (max_active): stop one first"))
    }
}

/// The block that makes `ssh dev-<name>` go through the gateway.
pub fn ssh_config_entry(cfg: &Config, name: &str) -> String {
    format!(
        "Host dev-{name}\n    HostName dev-{name}\n    User dev\n    Port 2222\n    ProxyJump jump@{}:{}\n    ForwardAgent no\n",
        cfg.ssh_host, cfg.ssh_port
    )
}

/// Session blocks live in their own file, `~/.ssh/devbox.conf`. Returns it
/// with `name`'s block present exactly once (replaced if it was there).
pub fn devbox_conf_with(conf: &str, entry: &str, name: &str) -> String {
    let rest = devbox_conf_without(conf, name);
    if rest.is_empty() { entry.to_string() } else { format!("{}\n\n{entry}", rest.trim_end()) }
}

/// `conf` without `name`'s block.
pub fn devbox_conf_without(conf: &str, name: &str) -> String {
    let host = format!("Host dev-{name}");
    let mut out = Vec::new();
    let mut skip = false;
    for line in conf.lines() {
        if line.trim_start().starts_with("Host ") {
            skip = line.trim() == host;
        }
        if !skip {
            out.push(line);
        }
    }
    let s = out.join("\n");
    let s = s.trim();
    if s.is_empty() { String::new() } else { format!("{s}\n") }
}

/// `~/.ssh/config` with `Include devbox.conf` as its first line, or None if
/// it already has it. First: ssh keeps the first value it reads, so a later
/// `Host *` must not override the session blocks.
pub fn ssh_config_including(config: &str) -> Option<String> {
    const INCLUDE: &str = "Include devbox.conf";
    if config.lines().any(|l| l.trim() == INCLUDE) {
        return None;
    }
    Some(if config.is_empty() { format!("{INCLUDE}\n") } else { format!("{INCLUDE}\n\n{config}") })
}

/// Replace an ~/.ssh file atomically (temp file + rename), so a crash or a
/// full disk never leaves the owner's ssh config truncated. A symlink (dotfiles
/// manager) is followed and kept; an existing file keeps its mode.
pub fn write_file(p: &std::path::Path, content: &str) -> Result<(), String> {
    let p = std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf());
    let err = |e: std::io::Error| format!("{}: {e}", p.display());
    let mut tmp = tempfile::NamedTempFile::new_in(p.parent().ok_or("no parent directory")?).map_err(err)?;
    std::io::Write::write_all(&mut tmp, content.as_bytes()).map_err(err)?;
    tmp.as_file().sync_all().map_err(err)?;
    if let Ok(m) = std::fs::metadata(&p) {
        tmp.as_file().set_permissions(m.permissions()).map_err(err)?;
    }
    tmp.persist(&p).map_err(|e| err(e.error))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{tests::MINIMAL, Config};

    #[test]
    fn env() {
        let cfg = Config::parse(MINIMAL).unwrap();
        let plugins = ["a@m".to_string(), "b@m".to_string()];
        let env = stack_env(&cfg, &NewSession { name: "jarvis", repo: "o/r", token: "ghp_x", plugins: &plugins, pubkeys: "k1,k2", s3_secret: "sek" });
        let mut keys: Vec<&str> = env.iter().map(|(k, _)| k.as_str()).collect();
        keys.sort();
        assert_eq!(keys, ["CPUS", "GH_TOKEN", "MARKETPLACES", "MEM_LIMIT", "PLUGINS", "REPO_URL", "S3_ACCESS_KEY", "S3_SECRET_KEY", "SESSION", "SSH_PUBKEYS"]);
        let get = |k: &str| env.iter().find(|(n, _)| n == k).unwrap().1.clone();
        assert_eq!(get("SESSION"), "jarvis");
        assert_eq!(get("REPO_URL"), "https://github.com/o/r");
        assert_eq!(get("GH_TOKEN"), "ghp_x");
        assert_eq!(get("PLUGINS"), "a@m,b@m");
        assert_eq!(get("MARKETPLACES"), "anthropics/claude-plugins-official");
        assert_eq!(get("SSH_PUBKEYS"), "k1,k2");
        assert_eq!(get("S3_ACCESS_KEY"), "devbox-jarvis");
        assert_eq!(get("S3_SECRET_KEY"), "sek");
        assert_eq!(get("MEM_LIMIT"), "1536m");
        assert_eq!(get("CPUS"), "2");
    }

    #[test]
    fn keys() {
        assert_eq!(pubkeys("ssh-ed25519 AAA me@mac\n", &[]).unwrap(), "ssh-ed25519 AAA me@mac");
        assert_eq!(pubkeys("ssh-ed25519 A m", &["ecdsa-sha2-nistp256 B pc".into()]).unwrap(), "ssh-ed25519 A m,ecdsa-sha2-nistp256 B pc");
        assert!(pubkeys("ssh-ed25519 A me,you", &[]).is_err());
        assert!(pubkeys("ssh-ed25519 A m", &["x\ny".into()]).is_err());
        assert!(pubkeys("", &[]).is_err());
    }

    #[test]
    fn cap() {
        assert!(check_cap(3, 4).is_ok());
        let e = check_cap(4, 4).unwrap_err();
        assert!(e.contains('4'), "{e}");
        assert!(check_cap(5, 4).is_err());
    }

    #[test]
    fn ssh_entry() {
        let cfg = Config::parse(MINIMAL).unwrap();
        let e = ssh_config_entry(&cfg, "jarvis");
        let lines: Vec<&str> = e.lines().map(str::trim).collect();
        assert_eq!(lines[0], "Host dev-jarvis");
        for want in ["HostName dev-jarvis", "User dev", "Port 2222", "ProxyJump jump@192.168.2.10:2222", "ForwardAgent no"] {
            assert!(lines.contains(&want), "missing {want:?} in\n{e}");
        }
    }

    #[test]
    fn devbox_conf() {
        let a = "Host dev-a\n    User dev\n";
        let b = "Host dev-b\n    User dev\n";
        let one = devbox_conf_with("", a, "a");
        assert_eq!(one, a);
        let two = devbox_conf_with(&one, b, "b");
        assert_eq!(two.matches("Host dev-").count(), 2);
        // Same name again: replaced, not duplicated.
        let again = devbox_conf_with(&two, "Host dev-a\n    User other\n", "a");
        assert_eq!(again.matches("Host dev-a\n").count(), 1);
        assert!(again.contains("User other") && again.contains("Host dev-b"));
        // "ab" is not "a".
        let ab = devbox_conf_with(&two, "Host dev-ab\n    User dev\n", "ab");
        assert_eq!(devbox_conf_without(&ab, "a").matches("Host dev-").count(), 2);
        assert!(!devbox_conf_without(&two, "a").contains("Host dev-a\n"));
        assert!(devbox_conf_without(&two, "a").contains("Host dev-b"));
    }

    #[test]
    fn include_first() {
        assert_eq!(ssh_config_including("").unwrap(), "Include devbox.conf\n");
        let c = ssh_config_including("Host *\n    User me\n").unwrap();
        assert!(c.starts_with("Include devbox.conf\n\nHost *"), "{c}");
        assert_eq!(ssh_config_including(&c), None);
    }

    #[cfg(unix)]
    #[test]
    fn write_keeps_link_and_mode() {
        use std::os::unix::fs::PermissionsExt;
        let d = tempfile::tempdir().unwrap();
        let real = d.path().join("real");
        std::fs::write(&real, "old").unwrap();
        std::fs::set_permissions(&real, std::fs::Permissions::from_mode(0o640)).unwrap();
        let link = d.path().join("config");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        write_file(&link, "new").unwrap();
        assert!(std::fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
        assert_eq!(std::fs::read_to_string(&real).unwrap(), "new");
        assert_eq!(std::fs::metadata(&real).unwrap().permissions().mode() & 0o777, 0o640);
        let fresh = d.path().join("fresh");
        write_file(&fresh, "x").unwrap();
        assert_eq!(std::fs::read_to_string(&fresh).unwrap(), "x");
        assert_eq!(std::fs::read_dir(d.path()).unwrap().count(), 3, "temp file left behind");
    }
}
