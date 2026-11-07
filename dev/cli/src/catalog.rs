//! Plugin marketplaces: `.claude-plugin/marketplace.json` of each catalog repo.
use serde::Deserialize;

#[derive(Debug, PartialEq)]
pub struct Plugin {
    /// `plugin@marketplace`, as `claude plugin install` takes it.
    pub id: String,
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
    description: String,
}

pub fn parse_marketplace(json: &str) -> Result<Vec<Plugin>, String> {
    let m: Marketplace = serde_json::from_str(json).map_err(|e| format!("marketplace.json: {e}"))?;
    Ok(m.plugins
        .into_iter()
        .map(|p| Plugin { id: format!("{}@{}", p.name, m.name), description: p.description })
        .collect())
}

/// Shallow-clones each catalog (`owner/repo` on GitHub) into a temp dir and
/// reads its marketplace. An unreachable catalog is a warning, not a failure.
pub fn fetch_all(catalogs: &[String]) -> Result<Vec<Plugin>, String> {
    let mut all = Vec::new();
    for c in catalogs {
        match fetch(c) {
            Ok(mut p) => all.append(&mut p),
            Err(e) => eprintln!("warning: catalog {c} skipped: {e}"),
        }
    }
    Ok(all)
}

fn fetch(catalog: &str) -> Result<Vec<Plugin>, String> {
    let dir = tempfile::tempdir().map_err(|e| e.to_string())?;
    let st = std::process::Command::new("git")
        .args(["clone", "--quiet", "--depth", "1", &format!("https://github.com/{catalog}")])
        .arg(dir.path())
        .status()
        .map_err(|e| format!("git: {e}"))?;
    if !st.success() {
        return Err("git clone failed".into());
    }
    let json = std::fs::read_to_string(dir.path().join(".claude-plugin/marketplace.json"))
        .map_err(|e| format!(".claude-plugin/marketplace.json: {e}"))?;
    parse_marketplace(&json)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses() {
        let p = parse_marketplace(r#"{"name":"m","plugins":[{"name":"p","description":"d"},{"name":"q"}]}"#).unwrap();
        assert_eq!(p, vec![
            Plugin { id: "p@m".into(), description: "d".into() },
            Plugin { id: "q@m".into(), description: "".into() },
        ]);
    }

    #[test]
    fn rejects() {
        assert!(parse_marketplace("not json").is_err());
        assert!(parse_marketplace(r#"{"name":"m"}"#).is_err());
    }
}
