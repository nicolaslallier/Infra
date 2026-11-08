//! Portainer's stack API (the same calls scripts/portainer-stack.sh makes),
//! plus its Docker proxy for volumes and for `weed shell` in the s3 container.
//! Session stacks are the ones named `dev-<name>`.
use crate::config::Config;
use reqwest::blocking::{Client as Http, RequestBuilder, Response};
use serde::Deserialize;
use serde_json::{json, Value};

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
    /// A client on the one Portainer environment that runs `project/service`
    /// (the data stack's s3 moves between hosts; nothing names the host).
    /// Environments that do not answer are skipped. Two matches (old and new
    /// s3 both up mid-migration) refuse: the identity would land on one.
    pub fn locate(cfg: &Config, project: &str, service: &str) -> Result<Client, String> {
        let mut c = Client::new(cfg)?;
        let envs: Vec<Value> = c.send(c.http.get(format!("{}/endpoints", c.base)), "list environments")?.json().map_err(|e| e.to_string())?;
        let hits: Vec<u32> = envs
            .iter()
            .filter_map(|e| e["Id"].as_u64())
            .map(|id| id as u32)
            .filter(|&id| {
                c.endpoint = id;
                c.container(project, service).is_ok()
            })
            .collect();
        match hits[..] {
            [id] => {
                c.endpoint = id;
                Ok(c)
            }
            [] => Err(format!("no running {project}/{service} container on any Portainer environment")),
            _ => Err(format!("{project}/{service} runs on several Portainer environments {hits:?}: stop the old one first")),
        }
    }

    fn container(&self, project: &str, service: &str) -> Result<String, String> {
        let filters = json!({"label": [format!("com.docker.compose.project={project}"), format!("com.docker.compose.service={service}")], "status": ["running"]});
        let list: Vec<Value> = self
            .send(self.http.get(self.docker("/containers/json")).query(&[("filters", filters.to_string())]), "find container")?
            .json()
            .map_err(|e| e.to_string())?;
        list.first().and_then(|c| c["Id"].as_str()).map(String::from).ok_or_else(|| format!("no running {project}/{service} container"))
    }

    pub fn new(cfg: &Config) -> Result<Client, String> {
        let mut b = Http::builder()
            // Stopping a stack waits for the session's final sync (up to 120s).
            .timeout(std::time::Duration::from_secs(300));
        if let Some(ca) = &cfg.ca_cert {
            let pem = std::fs::read(ca).map_err(|e| format!("ca_cert {}: {e}", ca.display()))?;
            let cert = reqwest::Certificate::from_pem(&pem).map_err(|e| format!("ca_cert {}: {e}", ca.display()))?;
            b = b.add_root_certificate(cert);
        }
        if cfg.insecure_tls {
            eprintln!("warning: insecure_tls: Portainer's certificate is not checked, the API key goes to whoever answers");
            b = b.danger_accept_invalid_certs(true);
        }
        Ok(Client {
            http: b.build().map_err(|e| e.to_string())?,
            base: format!("{}/api", cfg.portainer_url.trim_end_matches('/')),
            key: cfg.api_key.clone(),
            endpoint: cfg.endpoint_id,
        })
    }

    fn send(&self, req: RequestBuilder, what: &str) -> Result<Response, String> {
        let r = req.header("X-API-Key", &self.key).send().map_err(|e| format!("{what}: {e}"))?;
        if r.status().is_success() {
            Ok(r)
        } else {
            let status = r.status();
            Err(format!("{what}: Portainer answered {status}: {}", r.text().unwrap_or_default()))
        }
    }

    fn docker(&self, path: &str) -> String {
        format!("{}/endpoints/{}/docker{path}", self.base, self.endpoint)
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

    fn env_json(env: &[(String, String)]) -> Vec<Value> {
        env.iter().map(|(k, v)| json!({"name": k, "value": v})).collect()
    }

    pub fn create_stack(&self, name: &str, compose: &str, env: &[(String, String)]) -> Result<(), String> {
        let body = json!({"Name": name, "StackFileContent": compose, "Env": Self::env_json(env)});
        let url = format!("{}/stacks/create/standalone/string?endpointId={}", self.base, self.endpoint);
        self.send(self.http.post(url).json(&body), &format!("create {name}")).map(|_| ())
    }

    /// The stack's env, as Portainer stores it.
    pub fn stack_env(&self, id: u32) -> Result<Vec<(String, String)>, String> {
        let v: Value = self.send(self.http.get(format!("{}/stacks/{id}", self.base)), "read stack")?.json().map_err(|e| e.to_string())?;
        Ok(v["Env"]
            .as_array()
            .map(|a| a.iter().map(|e| (e["name"].as_str().unwrap_or("").to_string(), e["value"].as_str().unwrap_or("").to_string())).collect())
            .unwrap_or_default())
    }

    /// Redeploys a stack with this compose file and env (recreates the session).
    pub fn update_stack(&self, id: u32, compose: &str, env: &[(String, String)]) -> Result<(), String> {
        let body = json!({"StackFileContent": compose, "Env": Self::env_json(env), "Prune": false, "PullImage": false});
        let url = format!("{}/stacks/{id}?endpointId={}", self.base, self.endpoint);
        self.send(self.http.put(url).json(&body), "update stack").map(|_| ())
    }

    /// Portainer refuses (409 "deployment is in progress") to act on a stack
    /// it is still deploying -- e.g. right after a create or a token update.
    fn when_idle(&self, what: &str, req: impl Fn() -> RequestBuilder) -> Result<(), String> {
        for _ in 0..60 {
            match self.send(req(), what) {
                Err(e) if e.contains("409") && e.contains("in progress") => std::thread::sleep(std::time::Duration::from_secs(2)),
                r => return r.map(|_| ()),
            }
        }
        Err(format!("{what}: Portainer kept the stack busy for 2 minutes"))
    }

    fn action(&self, id: u32, verb: &str) -> Result<(), String> {
        let url = format!("{}/stacks/{id}/{verb}?endpointId={}", self.base, self.endpoint);
        self.when_idle(verb, || self.http.post(&url))
    }
    pub fn stop(&self, id: u32) -> Result<(), String> { self.action(id, "stop") }
    pub fn start(&self, id: u32) -> Result<(), String> { self.action(id, "start") }

    pub fn delete(&self, id: u32) -> Result<(), String> {
        let url = format!("{}/stacks/{id}?endpointId={}", self.base, self.endpoint);
        self.when_idle("delete", || self.http.delete(&url))
    }

    /// Deleting a stack leaves its volumes.
    pub fn delete_volume(&self, volume: &str) -> Result<(), String> {
        self.send(self.http.delete(self.docker(&format!("/volumes/{volume}"))), &format!("delete volume {volume}")).map(|_| ())
    }

    /// Runs `sh -euc <script>` in the running container of a compose
    /// service, with `env` in its environment (never in its argv), and waits
    /// for it. Detached and polled: Portainer's proxy and a hijacked exec
    /// stream do not mix.
    pub fn exec_in_service(&self, project: &str, service: &str, script: &str, env: &[(&str, &str)]) -> Result<(), String> {
        let id = self.container(project, service)?;
        let env: Vec<String> = env.iter().map(|(k, v)| format!("{k}={v}")).collect();
        let body = json!({"Cmd": ["sh", "-euc", script], "Env": env, "AttachStdout": false, "AttachStderr": false});
        let exec: Value = self.send(self.http.post(self.docker(&format!("/containers/{id}/exec"))).json(&body), "exec")?.json().map_err(|e| e.to_string())?;
        let eid = exec["Id"].as_str().ok_or("exec: no id")?.to_string();
        self.send(self.http.post(self.docker(&format!("/exec/{eid}/start"))).json(&json!({"Detach": true, "Tty": false})), "exec start")?;
        for _ in 0..120 {
            let st: Value = self.send(self.http.get(self.docker(&format!("/exec/{eid}/json"))), "exec status")?.json().map_err(|e| e.to_string())?;
            if st["Running"] == json!(false) {
                return match st["ExitCode"].as_i64() {
                    Some(0) => Ok(()),
                    c => Err(format!("{service}: command exited {c:?}")),
                };
            }
            std::thread::sleep(std::time::Duration::from_millis(500));
        }
        Err(format!("{service}: command still running after 60s"))
    }
}

/// Against a real (throwaway) Portainer:
/// `PT_URL=https://127.0.0.1:19443 PT_KEY=... S3_PROJECT=<label> cargo test -- --ignored`.
/// Needs devbox-session:1, the dev-net network, and a SeaweedFS container
/// labelled com.docker.compose.project=$S3_PROJECT, service s3, on that daemon.
#[cfg(test)]
mod live {
    use super::*;
    use crate::config::{tests::MINIMAL, Config};
    use crate::session::{stack_env, NewSession};

    #[test]
    #[ignore]
    fn stack_lifecycle() {
        let mut cfg = Config::parse(MINIMAL).unwrap();
        cfg.portainer_url = std::env::var("PT_URL").unwrap();
        cfg.api_key = std::env::var("PT_KEY").unwrap();
        cfg.endpoint_id = 1;
        cfg.insecure_tls = true;
        let project = std::env::var("S3_PROJECT").unwrap();
        let pt = Client::new(&cfg).unwrap();

        let secret = crate::s3::new_secret().unwrap();
        pt.exec_in_service(&project, "s3", crate::s3::CREATE, &[("N", "it"), ("K", &secret)]).unwrap();
        assert!(pt.exec_in_service(&project, "s3", "exit 3", &[]).is_err());

        let env = stack_env(&cfg, &NewSession { name: "it", repo: "o/r", token: "dummy", plugins: &[], pubkeys: "ssh-ed25519 AAA", s3_secret: &secret });
        pt.create_stack("dev-it", crate::COMPOSE, &env).unwrap();
        let running = || pt.list_stacks().unwrap().iter().find(|s| s.name == "dev-it").unwrap().running;
        // Portainer sets Status a moment after create returns.
        assert!((0..20).any(|_| running() || { std::thread::sleep(std::time::Duration::from_millis(500)); false }));
        let s = pt.list_stacks().unwrap().into_iter().find(|s| s.name == "dev-it").unwrap();

        let mut env2 = pt.stack_env(s.id).unwrap();
        assert!(env2.iter().any(|(k, v)| k == "GH_TOKEN" && v == "dummy"));
        for (k, v) in env2.iter_mut() { if k == "GH_TOKEN" { *v = "rotated".into(); } }
        pt.update_stack(s.id, crate::COMPOSE, &env2).unwrap();
        assert!(pt.stack_env(s.id).unwrap().iter().any(|(k, v)| k == "GH_TOKEN" && v == "rotated"));

        pt.stop(s.id).unwrap();
        assert!(!running());
        pt.start(s.id).unwrap();
        assert!(running());
        pt.delete(s.id).unwrap();
        pt.delete_volume("dev-it-work").unwrap();
        pt.delete_volume("dev-it-state").unwrap();
        pt.exec_in_service(&project, "s3", crate::s3::DELETE, &[("N", "it")]).unwrap();
        assert!(pt.list_stacks().unwrap().iter().all(|s| s.name != "dev-it"));
    }
}
