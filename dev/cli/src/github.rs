//! The one GitHub question the CLI asks: is `main` protected? The session's
//! token can merge to main, so branch protection is the real guard rail.
use serde::Deserialize;

#[derive(Deserialize)]
struct Branch {
    protected: bool,
}

/// Only a fine-grained PAT (`github_pat_`) can be limited to one repository;
/// a classic `ghp_` token with `repo` reaches every repo the owner has. (A
/// fine-grained token set to "All repositories" still passes: say so.)
pub fn check_token_kind(token: &str) -> Result<(), String> {
    if token.starts_with("github_pat_") {
        Ok(())
    } else {
        Err("not a fine-grained token (github_pat_...): create one limited to this repository only".into())
    }
}

pub fn main_is_protected(slug: &str, token: &str) -> Result<bool, String> {
    let r = reqwest::blocking::Client::new()
        .get(format!("https://api.github.com/repos/{slug}/branches/main"))
        .header("Authorization", format!("Bearer {token}"))
        .header("Accept", "application/vnd.github+json")
        .header("User-Agent", "devbox")
        .send()
        .map_err(|e| format!("GitHub: {e}"))?;
    match r.status().as_u16() {
        200 => r.json::<Branch>().map(|b| b.protected).map_err(|e| format!("GitHub: {e}")),
        401 => Err("GitHub refused the token (401)".into()),
        404 => Err(format!("{slug}: no branch main, or the token cannot read this repository")),
        s => Err(format!("GitHub answered {s} for {slug}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_kinds() {
        assert!(check_token_kind("github_pat_11ABC_xyz").is_ok());
        for bad in ["ghp_abc", "gho_abc", "ghs_abc", "", "abc"] {
            let e = check_token_kind(bad).unwrap_err();
            assert!(bad.is_empty() || !e.contains(bad), "token echoed in error: {e}");
        }
    }
}
