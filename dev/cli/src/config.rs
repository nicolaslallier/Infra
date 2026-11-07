use anyhow::{Context, Result};
use serde::Deserialize;
use std::fmt;
use std::path::PathBuf;

#[derive(Deserialize)]
pub struct Config {
    pub portainer_url: String,
    pub api_key: String,
    pub endpoint_id: u32,
    #[serde(default)]
    pub insecure_tls: bool,
    pub ssh_host: String,
    pub ssh_port: u16,
    pub pubkey_path: PathBuf,
    #[serde(default = "default_catalogs")]
    pub catalogs: Vec<String>,
    pub s3_secret_key: String,
    #[serde(default = "default_max_active")]
    pub max_active: usize,
    #[serde(default = "default_mem_limit")]
    pub mem_limit: String,
}

fn default_catalogs() -> Vec<String> {
    vec!["anthropics/claude-plugins-official".into()]
}
fn default_max_active() -> usize {
    4
}
fn default_mem_limit() -> String {
    "1536m".into()
}

impl fmt::Debug for Config {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Config")
            .field("portainer_url", &self.portainer_url)
            .field("api_key", &"<masqué>")
            .field("endpoint_id", &self.endpoint_id)
            .field("insecure_tls", &self.insecure_tls)
            .field("ssh_host", &self.ssh_host)
            .field("ssh_port", &self.ssh_port)
            .field("pubkey_path", &self.pubkey_path)
            .field("catalogs", &self.catalogs)
            .field("s3_secret_key", &"<masqué>")
            .field("max_active", &self.max_active)
            .field("mem_limit", &self.mem_limit)
            .finish()
    }
}

impl Config {
    pub fn parse(s: &str) -> Result<Config> {
        toml::from_str(s).context("config.toml invalide")
    }

    pub fn load() -> Result<Config> {
        let dirs = directories::ProjectDirs::from("net", "famillelallier", "devbox")
            .context("dossier de configuration introuvable")?;
        let path = dirs.config_dir().join("config.toml");
        let text = std::fs::read_to_string(&path)
            .with_context(|| format!("lecture de {}", path.display()))?;
        Self::parse(&text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MIN: &str = r#"
portainer_url = "https://p:9443"
api_key = "KEY-SECRET"
endpoint_id = 2
ssh_host = "192.168.2.10"
ssh_port = 2222
pubkey_path = "/k.pub"
s3_secret_key = "S3-SECRET"
"#;

    #[test]
    fn defaults() {
        let c = Config::parse(MIN).unwrap();
        assert_eq!(c.catalogs, ["anthropics/claude-plugins-official"]);
        assert_eq!(c.max_active, 4);
        assert_eq!(c.mem_limit, "1536m");
        assert!(!c.insecure_tls);
    }

    #[test]
    fn debug_hides_secrets() {
        let d = format!("{:?}", Config::parse(MIN).unwrap());
        assert!(!d.contains("KEY-SECRET") && !d.contains("S3-SECRET"));
    }
}
