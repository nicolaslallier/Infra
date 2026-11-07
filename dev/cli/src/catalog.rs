use serde::Deserialize;
use std::path::PathBuf;
use std::process::Command;

#[derive(Debug, PartialEq, Eq, Clone)]
pub struct Plugin {
    pub id: String, // plugin@marketplace
    pub description: String,
}

#[derive(Deserialize)]
struct Marketplace {
    name: String,
    plugins: Vec<Entry>,
}

#[derive(Deserialize)]
struct Entry {
    name: String,
    #[serde(default)]
    description: Option<String>,
}

// ids end up in env var lists and shell-ish contexts: only [A-Za-z0-9._-].
fn safe_name(s: &str) -> bool {
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
        return Ok(vec![]);
    }
    Ok(m.plugins
        .into_iter()
        .filter(|p| safe_name(&p.name))
        .map(|p| Plugin {
            id: format!("{}@{}", p.name, m.name),
            description: clean_description(p.description.as_deref().unwrap_or("")),
        })
        .collect())
}

fn fetch_one(slug: &str, dir: &PathBuf) -> Result<Vec<Plugin>, String> {
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
    let json = std::fs::read_to_string(dir.join(".claude-plugin").join("marketplace.json"))
        .map_err(|e| format!("marketplace.json illisible: {e}"))?;
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
        let res = fetch_one(&slug, &dir);
        let _ = std::fs::remove_dir_all(&dir);
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
            assert!(parse_marketplace(&json).unwrap().is_empty(), "{n}");
        }
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
