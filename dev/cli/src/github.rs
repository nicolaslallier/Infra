// Pure helper first so the parsing is testable without the network.
pub fn protected_from_json(body: &str) -> Result<bool, String> {
    let v: serde_json::Value =
        serde_json::from_str(body).map_err(|_| "réponse GitHub illisible".to_string())?;
    v.get("protected")
        .and_then(|p| p.as_bool())
        .ok_or_else(|| "réponse GitHub sans champ `protected`".to_string())
}

pub fn main_is_protected(slug: &str, token: &str) -> Result<bool, String> {
    // Plain client: never accepts invalid certs, whatever `insecure_tls` says.
    let resp = reqwest::blocking::Client::new()
        .get(format!("https://api.github.com/repos/{slug}/branches/main"))
        .header("Authorization", format!("Bearer {token}"))
        .header("User-Agent", "devbox")
        .header("Accept", "application/vnd.github+json")
        .send()
        .map_err(|e| format!("GitHub injoignable: {}", e.without_url()))?;
    match resp.status().as_u16() {
        200 => protected_from_json(&resp.text().map_err(|_| "réponse GitHub illisible")?),
        401 => Err("GitHub refuse le jeton (401)".into()),
        403 => Err("GitHub refuse l'accès (403): jeton sans droit sur ce dépôt?".into()),
        404 => Err(format!("dépôt ou branche main introuvable: {slug} (404)")),
        s => Err(format!("GitHub a répondu {s}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_protected() {
        assert_eq!(protected_from_json(r#"{"protected":true}"#), Ok(true));
        assert_eq!(protected_from_json(r#"{"protected":false}"#), Ok(false));
        assert!(protected_from_json(r#"{"name":"main"}"#).is_err());
        assert!(protected_from_json("nope").is_err());
    }
}
