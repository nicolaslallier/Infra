use crate::config::Config;
use serde_json::{json, Value};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Stack {
    pub id: u32,
    pub name: String,
    pub running: bool,
}

pub struct Client {
    base: String,
    key: String,
    ep: u32,
    http: reqwest::blocking::Client,
}

impl Client {
    pub fn new(cfg: &Config) -> Result<Client, String> {
        let http = reqwest::blocking::Client::builder()
            .danger_accept_invalid_certs(cfg.insecure_tls) // Portainer only
            .build()
            .map_err(|e| e.to_string())?;
        Ok(Client {
            base: cfg.portainer_url.trim_end_matches('/').to_string(),
            key: cfg.api_key.clone(),
            ep: cfg.endpoint_id,
            http,
        })
    }

    // Errors carry the status and Portainer's `message` only, never a body.
    fn call(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
    ) -> Result<Value, String> {
        let mut r = self
            .http
            .request(method, format!("{}/api{path}", self.base))
            .header("X-API-Key", &self.key);
        if let Some(b) = body {
            r = r.json(&b);
        }
        let resp = r
            .send()
            .map_err(|e| format!("Portainer injoignable: {}", e.without_url()))?;
        let status = resp.status();
        let text = resp.text().unwrap_or_default();
        let v: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
        if status.is_success() {
            return Ok(v);
        }
        let msg = v.get("message").and_then(|m| m.as_str()).unwrap_or("");
        Err(format!("Portainer a répondu {} {msg}", status.as_u16())
            .trim()
            .to_string())
    }

    pub fn list_stacks(&self) -> Result<Vec<Stack>, String> {
        let v = self.call(reqwest::Method::GET, "/stacks", None)?;
        Ok(v.as_array()
            .map(|a| a.iter().filter_map(parse_stack).collect())
            .unwrap_or_default())
    }

    pub fn create_stack(
        &self,
        name: &str,
        compose: &str,
        env: &[(String, String)],
    ) -> Result<(), String> {
        let env: Vec<Value> = env
            .iter()
            .map(|(n, v)| json!({"name": n, "value": v}))
            .collect();
        let body = json!({"name": name, "stackFileContent": compose, "env": env});
        let path = format!("/stacks/create/standalone/string?endpointId={}", self.ep);
        self.call(reqwest::Method::POST, &path, Some(body))
            .map(|_| ())
    }

    pub fn stop(&self, id: u32) -> Result<(), String> {
        let path = format!("/stacks/{id}/stop?endpointId={}", self.ep);
        self.call(reqwest::Method::POST, &path, None).map(|_| ())
    }

    pub fn start(&self, id: u32) -> Result<(), String> {
        let path = format!("/stacks/{id}/start?endpointId={}", self.ep);
        self.call(reqwest::Method::POST, &path, None).map(|_| ())
    }

    pub fn delete(&self, id: u32) -> Result<(), String> {
        let path = format!("/stacks/{id}?endpointId={}", self.ep);
        self.call(reqwest::Method::DELETE, &path, None).map(|_| ())
    }

    pub fn delete_volume(&self, name: &str) -> Result<(), String> {
        let path = format!("/endpoints/{}/docker/volumes/{name}", self.ep);
        self.call(reqwest::Method::DELETE, &path, None).map(|_| ())
    }
}

fn parse_stack(v: &Value) -> Option<Stack> {
    Some(Stack {
        id: v.get("Id")?.as_u64()? as u32,
        name: v.get("Name")?.as_str()?.to_string(),
        running: v.get("Status")?.as_u64()? == 1,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    // Answers `n` requests with canned JSON; returns the raw requests seen.
    fn stub(
        n: usize,
        status: &'static str,
        reply: &'static str,
    ) -> (String, std::thread::JoinHandle<Vec<String>>) {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", l.local_addr().unwrap());
        let h = std::thread::spawn(move || {
            let mut seen = vec![];
            for _ in 0..n {
                let (mut s, _) = l.accept().unwrap();
                let mut buf = vec![];
                let mut b = [0u8; 4096];
                loop {
                    let k = s.read(&mut b).unwrap();
                    buf.extend_from_slice(&b[..k]);
                    let t = String::from_utf8_lossy(&buf).to_string();
                    if let Some(i) = t.find("\r\n\r\n") {
                        let cl = t[..i]
                            .to_lowercase()
                            .lines()
                            .find_map(|l| {
                                l.strip_prefix("content-length: ")
                                    .map(|v| v.trim().parse::<usize>().unwrap())
                            })
                            .unwrap_or(0);
                        if buf.len() >= i + 4 + cl {
                            break;
                        }
                    }
                }
                seen.push(String::from_utf8_lossy(&buf).to_string());
                let r = format!("HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{reply}", reply.len());
                s.write_all(r.as_bytes()).unwrap();
            }
            seen
        });
        (base, h)
    }

    fn client(base: &str) -> Client {
        Client {
            base: base.into(),
            key: "K-123".into(),
            ep: 7,
            http: reqwest::blocking::Client::new(),
        }
    }

    #[test]
    fn requests_are_well_formed() {
        let (base, h) = stub(
            6,
            "200 OK",
            r#"[{"Id":3,"Name":"dev-a","Status":1},{"Id":4,"Name":"x","Status":2}]"#,
        );
        let c = client(&base);
        let l = c.list_stacks().unwrap();
        assert_eq!(
            l[0],
            Stack {
                id: 3,
                name: "dev-a".into(),
                running: true
            }
        );
        assert!(!l[1].running);
        let env = crate::session::stack_env(
            &Config::parse("portainer_url=\"x\"\napi_key=\"k\"\nendpoint_id=7\nssh_host=\"h\"\nssh_port=1\npubkey_path=\"/p\"\ns3_secret_key=\"s\"").unwrap(),
            "a", "o/r", "tok", &[], "ssh-ed25519 AAA",
        );
        c.create_stack("dev-a", "compose", &env).unwrap();
        c.stop(3).unwrap();
        c.start(3).unwrap();
        c.delete(3).unwrap();
        c.delete_volume("dev-a-work").unwrap();
        let seen = h.join().unwrap();
        let first = |i: usize| seen[i].lines().next().unwrap().to_string();
        assert_eq!(first(0), "GET /api/stacks HTTP/1.1");
        assert_eq!(
            first(1),
            "POST /api/stacks/create/standalone/string?endpointId=7 HTTP/1.1"
        );
        assert_eq!(first(2), "POST /api/stacks/3/stop?endpointId=7 HTTP/1.1");
        assert_eq!(first(3), "POST /api/stacks/3/start?endpointId=7 HTTP/1.1");
        assert_eq!(first(4), "DELETE /api/stacks/3?endpointId=7 HTTP/1.1");
        assert_eq!(
            first(5),
            "DELETE /api/endpoints/7/docker/volumes/dev-a-work HTTP/1.1"
        );
        for s in &seen {
            assert!(s.to_lowercase().contains("x-api-key: k-123"));
        }
        for n in [
            "SESSION",
            "REPO_URL",
            "GH_TOKEN",
            "PLUGINS",
            "MARKETPLACES",
            "SSH_PUBKEY",
            "S3_SECRET_KEY",
            "MEM_LIMIT",
        ] {
            assert!(seen[1].contains(&format!("\"name\":\"{n}\"")), "{n}");
        }
        assert!(seen[1].contains("\"name\":\"dev-a\"") && seen[1].contains("stackFileContent"));
    }

    #[test]
    fn error_has_status_and_message_only() {
        let (base, h) = stub(
            1,
            "500 Internal Server Error",
            r#"{"message":"boom","details":"SECRET-BODY"}"#,
        );
        let env = vec![("GH_TOKEN".to_string(), "ghp_TOKEN".to_string())];
        let e = client(&base).create_stack("dev-a", "c", &env).unwrap_err();
        h.join().unwrap();
        assert_eq!(e, "Portainer a répondu 500 boom");
        assert!(!e.contains("ghp_TOKEN") && !e.contains("SECRET-BODY") && !e.contains("K-123"));
    }
}
