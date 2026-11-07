//! Pure pieces of the session commands: stack env, the cap, the SSH entry.
use crate::config::Config;

/// The stack env dev/session.compose.yml reads. `repo` is `owner/repo`.
pub fn stack_env(cfg: &Config, name: &str, repo: &str, token: &str, plugins: &[String], pubkey: &str) -> Vec<(String, String)> {
    [
        ("SESSION", name.to_string()),
        ("REPO_URL", format!("https://github.com/{repo}")),
        ("GH_TOKEN", token.to_string()),
        ("MARKETPLACES", cfg.catalogs.join(",")),
        ("PLUGINS", plugins.join(",")),
        ("SSH_PUBKEY", pubkey.trim().to_string()),
        ("S3_SECRET_KEY", cfg.s3_secret_key.clone()),
        ("MEM_LIMIT", cfg.mem_limit.clone()),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v))
    .collect()
}

/// Refuses a create/resume that would exceed `max` running sessions.
pub fn check_cap(active: usize, max: usize) -> Result<(), String> {
    if active < max {
        Ok(())
    } else {
        Err(format!("{active} sessions running, the cap is {max} (max_active): stop one first"))
    }
}

/// The `~/.ssh/config` block that makes `ssh dev-<name>` go through the gateway.
pub fn ssh_config_entry(cfg: &Config, name: &str) -> String {
    format!(
        "Host dev-{name}\n    HostName dev-{name}\n    User dev\n    Port 2222\n    ProxyJump jump@{}:{}\n    ForwardAgent no\n",
        cfg.ssh_host, cfg.ssh_port
    )
}

/// `config` with the session's block appended, or None if `Host dev-<name>`
/// is already there (never a duplicate).
pub fn ssh_config_with(config: &str, entry: &str, name: &str) -> Option<String> {
    let host = format!("Host dev-{name}");
    if config.lines().any(|l| l.trim() == host) {
        return None;
    }
    let sep = if config.is_empty() || config.ends_with("\n\n") { "" } else if config.ends_with('\n') { "\n" } else { "\n\n" };
    Some(format!("{config}{sep}{entry}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{tests::MINIMAL, Config};

    #[test]
    fn env() {
        let cfg = Config::parse(MINIMAL).unwrap();
        let env = stack_env(&cfg, "jarvis", "o/r", "ghp_x", &["a@m".into(), "b@m".into()], "ssh-ed25519 AAA me");
        let mut keys: Vec<&str> = env.iter().map(|(k, _)| k.as_str()).collect();
        keys.sort();
        assert_eq!(keys, ["GH_TOKEN", "MARKETPLACES", "MEM_LIMIT", "PLUGINS", "REPO_URL", "S3_SECRET_KEY", "SESSION", "SSH_PUBKEY"]);
        let get = |k: &str| env.iter().find(|(n, _)| n == k).unwrap().1.clone();
        assert_eq!(get("SESSION"), "jarvis");
        assert_eq!(get("REPO_URL"), "https://github.com/o/r");
        assert_eq!(get("GH_TOKEN"), "ghp_x");
        assert_eq!(get("PLUGINS"), "a@m,b@m");
        assert_eq!(get("MARKETPLACES"), "anthropics/claude-plugins-official");
        assert_eq!(get("SSH_PUBKEY"), "ssh-ed25519 AAA me");
        assert_eq!(get("S3_SECRET_KEY"), "S3SECRETVALUE");
        assert_eq!(get("MEM_LIMIT"), "1536m");
    }

    #[test]
    fn cap() {
        assert!(check_cap(3, 4).is_ok());
        let e = check_cap(4, 4).unwrap_err();
        assert!(e.contains('4'), "{e}");
        assert!(check_cap(5, 4).is_err());
    }

    #[test]
    fn ssh_config_append_once() {
        let e = "Host dev-a\n    User dev\n";
        let once = ssh_config_with("Host x\n", e, "a").unwrap();
        assert_eq!(once, "Host x\n\nHost dev-a\n    User dev\n");
        assert_eq!(ssh_config_with(&once, e, "a"), None);
        assert_eq!(ssh_config_with("", e, "a").unwrap(), e);
        assert!(ssh_config_with(&once, e, "ab").is_some());
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
}
