//! One S3 identity per session: `devbox-<name>`, allowed to read, write and
//! list `devbox/<name>/*` only (SeaweedFS action scopes). Created and removed
//! by running `weed shell` in the stack's `s3` container through Portainer.

/// A fresh secret: 24 random bytes, hex.
pub fn new_secret() -> Result<String, String> {
    let mut b = [0u8; 24];
    getrandom::getrandom(&mut b).map_err(|e| e.to_string())?;
    Ok(b.iter().map(|x| format!("{x:02x}")).collect())
}

/// Shell run in the s3 container to create the bucket (versioned) if it is
/// missing and (re)create the session's identity. Reads N and K from the env:
/// the secret never enters an argv. N is a validated session name.
pub const CREATE: &str = r#"
ws() { printf '%s\n' "$1" | weed shell -master=s3:9333; }
# s3.bucket.create on an existing bucket replaces its entry (versioning
# included), so only create a missing one. Capture first: -e then aborts on a
# failed list instead of grep masking it.
list=$(ws "s3.bucket.list")
if ! printf '%s\n' "$list" | awk '{print $1}' | grep -qxF devbox; then
  ws "s3.bucket.create -name devbox"
  ws "s3.bucket.versioning -name devbox -enable"
fi
# s3.configure adds actions to an existing user: start from none.
ws "s3.configure -user devbox-$N -delete -apply" >/dev/null 2>&1 || true
ws "s3.configure -user devbox-$N -access_key devbox-$N -secret_key $K -actions Read:devbox/$N/*,Write:devbox/$N/*,List:devbox/$N/* -apply" >/dev/null
"#;

/// Removes the session's identity; its data stays in the bucket.
pub const DELETE: &str = r#"printf 's3.configure -user devbox-%s -delete -apply\n' "$N" | weed shell -master=s3:9333 >/dev/null"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secrets() {
        let a = new_secret().unwrap();
        assert_eq!(a.len(), 48);
        assert!(a.chars().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(a, new_secret().unwrap());
    }
}
