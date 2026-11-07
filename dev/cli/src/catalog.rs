use serde::Deserialize;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug, PartialEq, Eq, Clone)]
pub struct Plugin {
    pub id: String, // plugin@marketplace
    pub description: String,
}

#[derive(Deserialize)]
struct Marketplace {
    name: String,
    plugins: Vec<serde_json::Value>,
}

// ids end up in env var lists and shell-ish contexts: only [A-Za-z0-9._-].
pub(crate) fn safe_name(s: &str) -> bool {
    !s.is_empty()
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'-'))
}

fn clean_description(s: &str) -> String {
    s.chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect()
}

pub fn parse_marketplace(json: &str) -> Result<Vec<Plugin>, String> {
    let m: Marketplace =
        serde_json::from_str(json).map_err(|e| format!("marketplace.json invalide: {e}"))?;
    if !safe_name(&m.name) {
        return Err(format!("nom de marketplace non sûr: {:?}", m.name));
    }
    Ok(m.plugins
        .iter()
        .filter_map(|p| {
            let name = p.get("name")?.as_str().filter(|n| safe_name(n))?;
            let desc = p.get("description").and_then(|d| d.as_str()).unwrap_or("");
            Some(Plugin {
                id: format!("{name}@{}", m.name),
                description: clean_description(desc),
            })
        })
        .collect())
}

const MAX_JSON: u64 = 5 * 1024 * 1024;

// Removes the clone directory on every exit path, panics included.
struct TempDir(PathBuf);
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn fetch_one(slug: &str, dir: &Path) -> Result<Vec<Plugin>, String> {
    let st = Command::new("git")
        .args(["clone", "--depth", "1", "--quiet"])
        .arg(format!("https://github.com/{slug}"))
        .arg(dir)
        .env("GIT_TERMINAL_PROMPT", "0")
        .status()
        .map_err(|e| format!("git: {e}"))?;
    if !st.success() {
        return Err("git clone a échoué".into());
    }
    let file = dir.join(".claude-plugin").join("marketplace.json");
    let md = std::fs::symlink_metadata(&file).map_err(|e| format!("marketplace.json: {e}"))?;
    if !md.is_file() || md.len() >= MAX_JSON {
        return Err("marketplace.json n'est pas un fichier régulier de moins de 5 Mo".into());
    }
    let json =
        std::fs::read_to_string(&file).map_err(|e| format!("marketplace.json illisible: {e}"))?;
    parse_marketplace(&json)
}

pub fn fetch_all(catalogs: &[String]) -> Result<Vec<Plugin>, String> {
    let mut out: Vec<Plugin> = vec![];
    for (i, c) in catalogs.iter().enumerate() {
        let slug = match crate::validate::repo_slug(c) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("avertissement: catalogue ignoré: {e}");
                continue;
            }
        };
        let dir = std::env::temp_dir().join(format!("devbox-catalog-{}-{i}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let guard = TempDir(dir);
        let res = fetch_one(&slug, &guard.0);
        drop(guard);
        match res {
            Ok(ps) => {
                for p in ps {
                    if !out.iter().any(|o| o.id == p.id) {
                        out.push(p);
                    }
                }
            }
            Err(e) => eprintln!("avertissement: catalogue {slug} ignoré: {e}"),
        }
    }
    if out.is_empty() {
        Err("aucun plugin trouvé dans les catalogues".into())
    } else {
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_basic() {
        let ps = parse_marketplace(r#"{"name":"m","plugins":[{"name":"p","description":"d"}]}"#)
            .unwrap();
        assert_eq!(
            ps,
            vec![Plugin {
                id: "p@m".into(),
                description: "d".into()
            }]
        );
    }

    #[test]
    fn missing_description_is_empty() {
        let ps = parse_marketplace(r#"{"name":"m","plugins":[{"name":"p"}]}"#).unwrap();
        assert_eq!(ps[0].description, "");
    }

    #[test]
    fn invalid_or_no_plugins_is_err() {
        assert!(parse_marketplace("nope").is_err());
        assert!(parse_marketplace(r#"{"name":"m"}"#).is_err());
    }

    #[test]
    fn unsafe_plugin_names_skipped_valid_kept() {
        let json = r#"{"name":"m","plugins":[
            {"name":"a,b"},{"name":"a b"},{"name":"a@b"},{"name":"a;b"},{"name":"a/b"},{"name":""},
            {"name":"ok.p_1-x","description":"fine"}]}"#;
        let ps = parse_marketplace(json).unwrap();
        assert_eq!(ps.len(), 1);
        assert_eq!(ps[0].id, "ok.p_1-x@m");
    }

    #[test]
    fn unsafe_marketplace_name_yields_nothing() {
        for n in ["m,x", "m x", "m@x", "m;x", "m/x", ""] {
            let json = format!(r#"{{"name":"{n}","plugins":[{{"name":"p"}}]}}"#);
            assert!(parse_marketplace(&json).is_err(), "{n}");
        }
    }

    #[test]
    fn malformed_entries_skipped() {
        let json =
            r#"{"name":"m","plugins":[1,{"name":5},{"name":"ok"},{"name":"p2","description":7}]}"#;
        let ps = parse_marketplace(json).unwrap();
        assert_eq!(
            ps,
            vec![
                Plugin {
                    id: "ok@m".into(),
                    description: "".into()
                },
                Plugin {
                    id: "p2@m".into(),
                    description: "".into()
                },
            ]
        );
    }

    #[test]
    fn description_single_line() {
        let ps = parse_marketplace(
            r#"{"name":"m","plugins":[{"name":"p","description":"a\nb\r\tc\u001b[0m"}]}"#,
        )
        .unwrap();
        assert!(!ps[0].description.chars().any(|c| c.is_control()));
        assert!(ps[0].description.starts_with("a b"));
    }

    #[test]
    #[ignore]
    fn real_official_catalog() {
        let ps = fetch_all(&["anthropics/claude-plugins-official".into()]).unwrap();
        eprintln!("{} plugins", ps.len());
        assert!(!ps.is_empty());
    }
}
