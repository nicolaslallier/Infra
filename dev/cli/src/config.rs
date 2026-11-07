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
    /// Portainer's own certificate is self-signed.
    #[serde(default)]
    pub insecure_tls: bool,
    /// The LAN address nginx publishes :2222 on (LAN_IP).
    pub ssh_host: String,
    #[serde(default = "default_ssh_port")]
    pub ssh_port: u16,
    pub pubkey_path: PathBuf,
    /// Plugin marketplaces, as GitHub `owner/repo`.
    #[serde(default = "default_catalogs")]
    pub catalogs: Vec<String>,
    pub s3_secret_key: String,
    #[serde(default = "default_max_active")]
    pub max_active: usize,
    #[serde(default = "default_mem_limit")]
    pub mem_limit: String,
}

fn default_ssh_port() -> u16 { 2222 }
fn default_catalogs() -> Vec<String> { vec!["anthropics/claude-plugins-official".into()] }
fn default_max_active() -> usize { 4 }
fn default_mem_limit() -> String { "1536m".into() }

impl std::fmt::Debug for Config {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        f.debug_struct("Config")
            .field("portainer_url", &self.portainer_url)
            .field("api_key", &"<hidden>")
            .field("endpoint_id", &self.endpoint_id)
            .field("insecure_tls", &self.insecure_tls)
            .field("ssh_host", &self.ssh_host)
            .field("ssh_port", &self.ssh_port)
            .field("pubkey_path", &self.pubkey_path)
            .field("catalogs", &self.catalogs)
            .field("s3_secret_key", &"<hidden>")
            .field("max_active", &self.max_active)
            .field("mem_limit", &self.mem_limit)
            .finish()
    }
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
s3_secret_key = "S3SECRETVALUE"
"#;

    #[test]
    fn defaults() {
        let c = Config::parse(MINIMAL).unwrap();
        assert_eq!(c.catalogs, vec!["anthropics/claude-plugins-official"]);
        assert_eq!(c.max_active, 4);
        assert_eq!(c.mem_limit, "1536m");
        assert_eq!(c.ssh_port, 2222);
        assert!(!c.insecure_tls);
    }

    #[test]
    fn debug_hides_secrets() {
        let d = format!("{:?}", Config::parse(MINIMAL).unwrap());
        assert!(!d.contains("SECRETAPIKEY") && !d.contains("S3SECRETVALUE"), "{d}");
        assert!(d.contains("192.168.2.10"), "{d}");
    }

    #[test]
    fn missing_key_is_an_error() {
        assert!(Config::parse("portainer_url = \"x\"").is_err());
    }
}
