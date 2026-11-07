//! The one GitHub question the CLI asks: is `main` protected? The session's
//! token can merge to main, so branch protection is the real guard rail.
use serde::Deserialize;

#[derive(Deserialize)]
struct Branch {
    protected: bool,
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
