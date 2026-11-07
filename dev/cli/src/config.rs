//! `config.toml` in the OS config dir (e.g. ~/Library/Application
//! Support/net.famillelallier.devbox on macOS, %APPDATA%\famillelallier\devbox
//! on Windows). It holds the Portainer API key -- root on the Docker daemon --
//! so it stays on the owner's machine and `Debug` never prints the secrets.
use serde::Deserialize;
use std::path::PathBuf;

#[derive(Deserialize)]
pub struct Config {
    pub portainer_url: String,
    pub api_key: String,
    pub endpoint_id: u32,
    /// PEM of the CA that signed Portainer's certificate (the stack's own
    /// certs/infra-ca.crt when portainer_url is the nginx vhost).
    #[serde(default)]
    pub ca_cert: Option<PathBuf>,
    /// Skips certificate checks: anyone on the LAN who can take Portainer's
    /// address then collects the API key. Prefer ca_cert.
    #[serde(default)]
    pub insecure_tls: bool,
    /// The LAN address nginx publishes :2222 on (LAN_IP).
    pub ssh_host: String,
    #[serde(default = "default_ssh_port")]
    pub ssh_port: u16,
    pub pubkey_path: PathBuf,
    /// Public keys of the owner's other machines, so they can SSH in too.
    #[serde(default)]
    pub extra_pubkeys: Vec<String>,
    /// Plugin marketplaces, as GitHub `owner/repo`.
    #[serde(default = "default_catalogs")]
    pub catalogs: Vec<String>,
    #[serde(default = "default_max_active")]
    pub max_active: usize,
    #[serde(default = "default_mem_limit")]
    pub mem_limit: String,
    #[serde(default = "default_cpus")]
    pub cpus: String,
}

fn default_ssh_port() -> u16 { 2222 }
fn default_catalogs() -> Vec<String> { vec!["anthropics/claude-plugins-official".into()] }
fn default_max_active() -> usize { 4 }
fn default_mem_limit() -> String { "1536m".into() }
fn default_cpus() -> String { "2".into() }

impl std::fmt::Debug for Config {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        f.debug_struct("Config")
            .field("portainer_url", &self.portainer_url)
            .field("api_key", &"<hidden>")
            .field("endpoint_id", &self.endpoint_id)
            .field("ca_cert", &self.ca_cert)
            .field("insecure_tls", &self.insecure_tls)
            .field("ssh_host", &self.ssh_host)
            .field("ssh_port", &self.ssh_port)
            .field("pubkey_path", &self.pubkey_path)
            .field("extra_pubkeys", &self.extra_pubkeys.len())
            .field("catalogs", &self.catalogs)
            .field("max_active", &self.max_active)
            .field("mem_limit", &self.mem_limit)
            .field("cpus", &self.cpus)
            .finish()
    }
}

/// A warning when the file holding the Portainer key (root on the daemon) is
/// readable by anyone but its owner.
pub fn loose_mode(mode: u32) -> Option<String> {
    (mode & 0o077 != 0).then(|| format!("mode {:o} lets others read the Portainer API key; chmod 600 it", mode & 0o777))
}

impl Config {
    pub fn path() -> Result<PathBuf, String> {
        directories::ProjectDirs::from("net", "famillelallier", "devbox")
            .map(|d| d.config_dir().join("config.toml"))
            .ok_or_else(|| "no home directory".to_string())
    }

    pub fn load() -> Result<Config, String> {
        let p = Self::path()?;
        let text = std::fs::read_to_string(&p).map_err(|e| format!("{}: {e}", p.display()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if let Some(w) = std::fs::metadata(&p).ok().and_then(|m| loose_mode(m.permissions().mode())) {
                eprintln!("warning: {}: {w}", p.display());
            }
        }
        Self::parse(&text).map_err(|e| format!("{}: {e}", p.display()))
    }

    pub fn parse(text: &str) -> Result<Config, String> {
        toml::from_str(text).map_err(|e| e.to_string())
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;

    pub const MINIMAL: &str = r#"
portainer_url = "https://192.168.2.10:9443"
api_key = "ptr_SECRETAPIKEY"
endpoint_id = 3
ssh_host = "192.168.2.10"
pubkey_path = "/home/me/.ssh/id_ed25519.pub"
"#;

    #[test]
    fn defaults() {
        let c = Config::parse(MINIMAL).unwrap();
        assert_eq!(c.catalogs, vec!["anthropics/claude-plugins-official"]);
        assert_eq!(c.max_active, 4);
        assert_eq!(c.mem_limit, "1536m");
        assert_eq!(c.ssh_port, 2222);
        assert!(!c.insecure_tls);
        assert!(c.ca_cert.is_none());
        assert!(c.extra_pubkeys.is_empty());
        assert_eq!(c.cpus, "2");
    }

    #[test]
    fn debug_hides_secrets() {
        let d = format!("{:?}", Config::parse(MINIMAL).unwrap());
        assert!(!d.contains("SECRETAPIKEY"), "{d}");
        assert!(d.contains("192.168.2.10"), "{d}");
    }

    #[test]
    fn mode_warning() {
        assert!(loose_mode(0o600).is_none());
        assert!(loose_mode(0o644).unwrap().contains("644"));
        assert!(loose_mode(0o640).is_some());
    }

    #[test]
    fn missing_key_is_an_error() {
        assert!(Config::parse("portainer_url = \"x\"").is_err());
    }
}
