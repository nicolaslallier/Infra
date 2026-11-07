pub fn session_name(s: &str) -> Result<&str, String> {
    let b = s.as_bytes();
    let ok_char = |c: &u8| c.is_ascii_lowercase() || c.is_ascii_digit();
    let valid = (3..=32).contains(&b.len())
        && ok_char(&b[0])
        && ok_char(&b[b.len() - 1])
        && b.iter().all(|c| ok_char(c) || *c == b'-');
    if ["egress", "gateway"].contains(&s) {
        // dev-egress / dev-gateway are the shared infra's container names.
        Err(format!(
            "nom de session '{s}' réservé (dev-{s} est l'infra partagée)"
        ))
    } else if valid {
        Ok(s)
    } else {
        Err(format!(
            "nom de session invalide '{s}' (3-32 car., a-z 0-9 -, ni début ni fin par -)"
        ))
    }
}

pub fn repo_slug(url: &str) -> Result<String, String> {
    let rest = ["https://github.com/", "git@github.com:"]
        .iter()
        .find_map(|p| url.strip_prefix(p))
        .unwrap_or(url);
    let rest = rest.strip_suffix(".git").unwrap_or(rest);
    let part_ok = |p: &str| {
        !p.is_empty()
            && p != "."
            && p != ".."
            && p.bytes()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_' | b'.'))
    };
    match rest.split_once('/') {
        Some((o, r)) if part_ok(o) && part_ok(r) => Ok(format!("{o}/{r}")),
        _ if url.contains("://") || url.contains('@') => Err(format!(
            "dépôt invalide '{url}': seul github.com est supporté (attendu owner/repo)"
        )),
        _ => Err(format!(
            "dépôt GitHub invalide '{url}' (attendu owner/repo)"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_ok() {
        assert_eq!(session_name("jarvis"), Ok("jarvis"));
        assert!(session_name("abc").is_ok());
        assert!(session_name(&"a".repeat(32)).is_ok());
    }

    #[test]
    fn names_refused() {
        for n in ["Jarvis", "a", "ab", "a b", "a_b", "-ab", "ab-", "a..b", ""] {
            assert!(session_name(n).is_err(), "{n}");
        }
        assert!(session_name(&"a".repeat(33)).is_err());
    }

    #[test]
    fn reserved_names_refused() {
        // container_name dev-<name> would collide with the shared infra.
        for n in ["egress", "gateway"] {
            assert!(session_name(n).unwrap_err().contains("réservé"), "{n}");
        }
    }

    #[test]
    fn slugs_ok() {
        for u in [
            "https://github.com/o/r",
            "https://github.com/o/r.git",
            "git@github.com:o/r.git",
            "o/r",
        ] {
            assert_eq!(repo_slug(u).as_deref(), Ok("o/r"), "{u}");
        }
    }

    #[test]
    fn dot_github_repo_ok() {
        assert_eq!(repo_slug("o/.github").as_deref(), Ok("o/.github"));
    }

    #[test]
    fn slugs_refused() {
        for u in [
            "https://gitlab.com/o/r",
            "https://github.com/o",
            "https://github.com/o/r/extra",
            "../x",
            "o/..",
            "./r",
            "o/r;rm",
        ] {
            assert!(repo_slug(u).is_err(), "{u}");
        }
    }
}

#[cfg(test)]
mod host_msg {
    use super::*;

    #[test]
    fn other_host_message() {
        for u in ["https://gitlab.com/o/r", "git@gitlab.com:o/r.git"] {
            assert!(repo_slug(u)
                .unwrap_err()
                .contains("seul github.com est supporté"));
        }
    }
}
