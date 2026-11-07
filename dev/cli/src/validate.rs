//! Input checks done before any network call.

/// A session name becomes a hostname (`dev-<name>`), a bucket prefix and a
/// Portainer stack name: `^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$`.
pub fn session_name(s: &str) -> Result<&str, String> {
    let b = s.as_bytes();
    let inner = |c: &u8| c.is_ascii_lowercase() || c.is_ascii_digit();
    let ok = (3..=32).contains(&b.len())
        && inner(&b[0])
        && inner(&b[b.len() - 1])
        && b.iter().all(|c| inner(c) || *c == b'-');
    if ok {
        Ok(s)
    } else {
        Err(format!(
            "invalid session name {s:?}: 3 to 32 of a-z, 0-9 and '-', not starting or ending with '-'"
        ))
    }
}

/// `owner/repo` from a GitHub URL (https, ssh, with or without `.git`) or a
/// bare `owner/repo`. Anything else, including non-GitHub hosts, is refused.
pub fn repo_slug(url: &str) -> Result<String, String> {
    let err = || format!("not a GitHub repository: {url:?} (expected https://github.com/owner/repo or owner/repo)");
    let path = ["https://github.com/", "git@github.com:", "ssh://git@github.com/"]
        .iter()
        .find_map(|p| url.strip_prefix(p))
        .unwrap_or(if url.contains(':') { "" } else { url });
    let path = path.trim_end_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path);
    let parts: Vec<&str> = path.split('/').collect();
    let part_ok = |p: &&str| {
        !p.is_empty() && !p.starts_with('.') && p.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
    };
    match parts.as_slice() {
        [o, r] if part_ok(o) && part_ok(r) => Ok(format!("{o}/{r}")),
        _ => Err(err()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_names() {
        assert_eq!(session_name("jarvis"), Ok("jarvis"));
        assert_eq!(session_name("a-1b"), Ok("a-1b"));
        assert!(session_name(&"a".repeat(32)).is_ok());
        for bad in ["Jarvis", "a", "a_b", "-ab", "ab-", "a..b", "", "a b"] {
            assert!(session_name(bad).is_err(), "{bad:?} accepted");
        }
        assert!(session_name(&"a".repeat(33)).is_err());
    }

    #[test]
    fn repo_slugs() {
        for ok in ["https://github.com/o/r", "https://github.com/o/r.git", "git@github.com:o/r.git", "o/r", "https://github.com/o/r/"] {
            assert_eq!(repo_slug(ok).as_deref(), Ok("o/r"), "{ok}");
        }
        for bad in ["https://gitlab.com/o/r", "https://github.com/o", "https://github.com/o/r/extra", "o/../r", "", "http://github.com.evil.io/o/r"] {
            assert!(repo_slug(bad).is_err(), "{bad:?} accepted");
        }
    }
}
