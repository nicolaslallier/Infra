//! Portainer's stack API (the same calls scripts/portainer-stack.sh makes).
//! Session stacks are the ones named `dev-<name>`.
use crate::config::Config;
use reqwest::blocking::{Client as Http, RequestBuilder};
use serde::Deserialize;
use serde_json::json;

pub struct Client {
    http: Http,
    base: String,
    key: String,
    endpoint: u32,
}

#[derive(Deserialize)]
struct RawStack {
    #[serde(rename = "Id")]
    id: u32,
    #[serde(rename = "Name")]
    name: String,
    /// 1 active, 2 inactive.
    #[serde(rename = "Status")]
    status: u8,
}

pub struct Stack {
    pub id: u32,
    pub name: String,
    pub running: bool,
}

impl Client {
    pub fn new(cfg: &Config) -> Result<Client, String> {
        let http = Http::builder()
            .danger_accept_invalid_certs(cfg.insecure_tls)
            // Stopping a stack waits for the session's final sync (up to 120s).
            .timeout(std::time::Duration::from_secs(300))
            .build()
            .map_err(|e| e.to_string())?;
        Ok(Client {
            http,
            base: format!("{}/api", cfg.portainer_url.trim_end_matches('/')),
            key: cfg.api_key.clone(),
            endpoint: cfg.endpoint_id,
        })
    }

    fn send(&self, req: RequestBuilder, what: &str) -> Result<reqwest::blocking::Response, String> {
        let r = req.header("X-API-Key", &self.key).send().map_err(|e| format!("{what}: {e}"))?;
        if r.status().is_success() {
            Ok(r)
        } else {
            let status = r.status();
            Err(format!("{what}: Portainer answered {status}: {}", r.text().unwrap_or_default()))
        }
    }

    pub fn list_stacks(&self) -> Result<Vec<Stack>, String> {
        let raw: Vec<RawStack> = self
            .send(self.http.get(format!("{}/stacks", self.base)), "list stacks")?
            .json()
            .map_err(|e| format!("list stacks: {e}"))?;
        Ok(raw
            .into_iter()
            .filter(|s| s.name.starts_with("dev-"))
            .map(|s| Stack { id: s.id, name: s.name, running: s.status == 1 })
            .collect())
    }

    pub fn create_stack(&self, name: &str, compose: &str, env: &[(String, String)]) -> Result<(), String> {
        let env: Vec<_> = env.iter().map(|(k, v)| json!({"name": k, "value": v})).collect();
        let body = json!({"Name": name, "StackFileContent": compose, "Env": env});
        let url = format!("{}/stacks/create/standalone/string?endpointId={}", self.base, self.endpoint);
        self.send(self.http.post(url).json(&body), &format!("create {name}")).map(|_| ())
    }

    fn action(&self, id: u32, verb: &str) -> Result<(), String> {
        let url = format!("{}/stacks/{id}/{verb}?endpointId={}", self.base, self.endpoint);
        self.send(self.http.post(url), verb).map(|_| ())
    }
    pub fn stop(&self, id: u32) -> Result<(), String> { self.action(id, "stop") }
    pub fn start(&self, id: u32) -> Result<(), String> { self.action(id, "start") }

    pub fn delete(&self, id: u32) -> Result<(), String> {
        let url = format!("{}/stacks/{id}?endpointId={}", self.base, self.endpoint);
        self.send(self.http.delete(url), "delete").map(|_| ())
    }

    /// Through Portainer's Docker proxy: deleting a stack leaves its volumes.
    pub fn delete_volume(&self, volume: &str) -> Result<(), String> {
        let url = format!("{}/endpoints/{}/docker/volumes/{volume}", self.base, self.endpoint);
        self.send(self.http.delete(url), &format!("delete volume {volume}")).map(|_| ())
    }
}

/// Against a real (throwaway) Portainer:
/// `PT_URL=https://127.0.0.1:19443 PT_KEY=... cargo test -- --ignored`.
/// Needs devbox-session:1 and the dev-net network on that daemon.
#[cfg(test)]
mod live {
    use super::*;
    use crate::config::{tests::MINIMAL, Config};

    #[test]
    #[ignore]
    fn stack_lifecycle() {
        let mut cfg = Config::parse(MINIMAL).unwrap();
        cfg.portainer_url = std::env::var("PT_URL").unwrap();
        cfg.api_key = std::env::var("PT_KEY").unwrap();
        cfg.endpoint_id = 1;
        cfg.insecure_tls = true;
        let pt = Client::new(&cfg).unwrap();
        let env = crate::session::stack_env(&cfg, "it", "o/r", "dummy", &[], "ssh-ed25519 AAA");
        pt.create_stack("dev-it", crate::COMPOSE, &env).unwrap();
        let running = || pt.list_stacks().unwrap().iter().find(|s| s.name == "dev-it").unwrap().running;
        // Portainer sets Status a moment after create returns.
        assert!((0..20).any(|_| running() || { std::thread::sleep(std::time::Duration::from_millis(500)); false }));
        let s = pt.list_stacks().unwrap().into_iter().find(|s| s.name == "dev-it").unwrap();
        pt.stop(s.id).unwrap();
        assert!(!running());
        pt.start(s.id).unwrap();
        assert!(running());
        pt.delete(s.id).unwrap();
        pt.delete_volume("dev-it-work").unwrap();
        assert!(pt.list_stacks().unwrap().iter().all(|s| s.name != "dev-it"));
    }
}
