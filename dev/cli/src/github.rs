//! What the CLI checks about the repo and the token before a session gets
//! them. The token can merge to the default branch, so that branch's
//! protection -- and the token's inability to lift it -- is the guard rail.
use serde::Deserialize;
use std::time::Duration;

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

#[derive(Deserialize)]
struct Repo {
    default_branch: String,
}

#[derive(Deserialize)]
struct Branch {
    protected: bool,
}

fn get(url: &str, token: &str) -> Result<reqwest::blocking::Response, String> {
    reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(20))
        .build()
        .map_err(|e| e.to_string())?
        .get(url)
        .header("Authorization", format!("Bearer {token}"))
        .header("Accept", "application/vnd.github+json")
        .header("User-Agent", "devbox")
        .send()
        .map_err(|e| format!("GitHub: {e}"))
}

/// Ok(default branch) when it is protected and the token cannot administer
/// the repo (an admin token could bypass or remove that protection).
pub fn check_repo(slug: &str, token: &str) -> Result<String, String> {
    let r = get(&format!("https://api.github.com/repos/{slug}"), token)?;
    let repo: Repo = match r.status().as_u16() {
        200 => r.json().map_err(|e| format!("GitHub: {e}"))?,
        401 => return Err("GitHub refused the token (401)".into()),
        404 => return Err(format!("{slug}: not found, or the token cannot read it")),
        s => return Err(format!("GitHub answered {s} for {slug}")),
    };
    let b = &repo.default_branch;
    let r = get(&format!("https://api.github.com/repos/{slug}/branches/{b}"), token)?;
    if !r.status().is_success() {
        return Err(format!("GitHub answered {} for branch {b} of {slug}", r.status()));
    }
    if !r.json::<Branch>().map_err(|e| format!("GitHub: {e}"))?.protected {
        return Err(format!("{b} of {slug} is not protected: turn on branch protection (or a ruleset) for {b} first"));
    }
    // Reading the protection settings takes the Administration permission,
    // which also allows changing them. The token must not have it.
    let r = get(&format!("https://api.github.com/repos/{slug}/branches/{b}/protection"), token)?;
    let status = r.status().as_u16();
    admin_probe(status, &r.text().unwrap_or_default()).map_err(|e| format!("{slug}: {e}"))?;
    Ok(repo.default_branch)
}

/// The answer to GET .../branches/{b}/protection, read fail-closed: Ok only
/// when GitHub refuses it for lack of the Administration permission.
pub fn admin_probe(status: u16, body: &str) -> Result<(), String> {
    const ADMIN: &str = "the token has the Administration permission: it could lift the branch's protection. Give it Contents and Pull requests only";
    match status {
        403 => Ok(()),
        200..=299 => Err(ADMIN.into()),
        // Only a token that may read protection gets told there is none
        // (a branch protected by rulesets alone).
        404 if body.contains("not protected") => Err(ADMIN.into()),
        s => Err(format!("could not verify the token lacks the Administration permission (GitHub answered {s}); try again")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn admin_probe_fails_closed() {
        // Only GitHub refusing the permission proves the token lacks it.
        assert!(admin_probe(403, r#"{"message":"Resource not accessible by personal access token"}"#).is_ok());
        // An answer at all means the token can read (so change) protection.
        assert!(admin_probe(200, "{}").is_err());
        // Rulesets only: an admin token gets 404 "Branch not protected".
        assert!(admin_probe(404, r#"{"message":"Branch not protected"}"#).is_err());
        // Anything else cannot prove anything.
        for s in [404, 429, 500, 502, 301] {
            assert!(admin_probe(s, r#"{"message":"Not Found"}"#).is_err(), "{s}");
        }
    }

    #[test]
    fn token_kinds() {
        assert!(check_token_kind("github_pat_11ABC_xyz").is_ok());
        for bad in ["ghp_abc", "gho_abc", "ghs_abc", "", "abc"] {
            let e = check_token_kind(bad).unwrap_err();
            assert!(bad.is_empty() || !e.contains(bad), "token echoed in error: {e}");
        }
    }
}
