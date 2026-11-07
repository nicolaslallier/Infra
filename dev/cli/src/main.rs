//! devbox: Claude Code dev sessions, one Portainer stack each.
//! See CLAUDE.md "Dev sessions" in the Infra repo.
mod catalog;
mod config;
mod github;
mod portainer;
mod s3;
mod session;
mod validate;

use clap::{Parser, Subcommand};
use std::path::PathBuf;

#[derive(Parser)]
#[command(version, about)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Create a session for a GitHub repo and print how to SSH in
    Create {
        name: String,
        /// https://github.com/owner/repo, git@github.com:owner/repo or owner/repo
        #[arg(long)]
        repo: Option<String>,
        /// plugin@marketplace; repeat for several. Omit to pick interactively.
        #[arg(long = "plugin")]
        plugins: Vec<String>,
    },
    /// List sessions and their state
    List,
    /// Stop a session (its state is pushed to the bucket first)
    Stop { name: String },
    /// Start a stopped session again
    Resume { name: String },
    /// Replace a session's GitHub token (fine-grained tokens expire)
    Token { name: String },
    /// Delete a session: stack, volumes, S3 identity (the bucket copy is kept)
    Delete {
        name: String,
        /// Don't ask for confirmation
        #[arg(long)]
        yes: bool,
    },
}

const COMPOSE: &str = include_str!("../../session.compose.yml");
/// Compose project and service of the SeaweedFS container in the infra stack.
const S3_PROJECT: &str = "infra";

fn main() {
    let cli = Cli::parse();
    let result = config::Config::load().and_then(|cfg| match cli.cmd {
        Cmd::Create { name, repo, plugins } => create(&cfg, &name, repo, plugins),
        Cmd::List => list(&cfg),
        Cmd::Stop { name } => stop(&cfg, &name),
        Cmd::Resume { name } => resume(&cfg, &name),
        Cmd::Token { name } => token(&cfg, &name),
        Cmd::Delete { name, yes } => delete(&cfg, &name, yes),
    });
    if let Err(e) = result {
        eprintln!("devbox: {e}");
        std::process::exit(1);
    }
}

fn running(stacks: &[portainer::Stack]) -> usize {
    stacks.iter().filter(|s| s.running).count()
}

/// `name` is validated by the caller, before any network call.
fn find<'a>(stacks: &'a [portainer::Stack], name: &str) -> Result<&'a portainer::Stack, String> {
    let stack = format!("dev-{name}");
    stacks.iter().find(|s| s.name == stack).ok_or_else(|| format!("no session {name}"))
}

fn ask_token(slug: &str) -> Result<String, String> {
    let token = dialoguer::Password::new()
        .with_prompt(format!("GitHub token for {slug} only (fine-grained: Contents + Pull requests, this one repository)"))
        .interact()
        .map_err(|e| e.to_string())?;
    github::check_token_kind(&token)?;
    github::check_repo(slug, &token)?;
    Ok(token)
}

fn ssh_dir() -> Result<PathBuf, String> {
    Ok(directories::BaseDirs::new().ok_or("no home directory")?.home_dir().join(".ssh"))
}

fn create(cfg: &config::Config, name: &str, repo: Option<String>, mut plugins: Vec<String>) -> Result<(), String> {
    let name = validate::session_name(name)?;
    for p in &plugins {
        validate::plugin_id(p)?;
    }
    let primary = std::fs::read_to_string(&cfg.pubkey_path).map_err(|e| format!("{}: {e}", cfg.pubkey_path.display()))?;
    let pubkeys = session::pubkeys(&primary, &cfg.extra_pubkeys)?;
    let slug = match &repo {
        Some(r) => validate::repo_slug(r)?,
        None => validate::repo_slug(&dialoguer::Input::<String>::new().with_prompt("GitHub repository").interact_text().map_err(|e| e.to_string())?)?,
    };

    let pt = portainer::Client::new(cfg)?;
    let stacks = pt.list_stacks()?;
    if stacks.iter().any(|s| s.name == format!("dev-{name}")) {
        return Err(format!("session {name} already exists (devbox resume {name}, or devbox delete {name})"));
    }
    session::check_cap(running(&stacks), cfg.max_active)?;
    let token = ask_token(&slug)?;

    if plugins.is_empty() {
        let all = catalog::fetch_all(&cfg.catalogs)?;
        if all.is_empty() {
            eprintln!("warning: no plugin catalog could be read; creating the session without plugins");
        } else {
            let items: Vec<String> = all
                .iter()
                .map(|p| format!("{} -- {}", p.id, p.description.chars().take(70).collect::<String>()))
                .collect();
            let picked = dialoguer::MultiSelect::new()
                .with_prompt("Plugins (space to pick, enter to confirm)")
                .items(&items)
                .max_length(20)
                .interact()
                .map_err(|e| e.to_string())?;
            plugins = picked.into_iter().map(|i| all[i].id.clone()).collect();
        }
    }

    let secret = s3::new_secret()?;
    pt.exec_in_service(S3_PROJECT, "s3", s3::CREATE, &[("N", name), ("K", &secret)])
        .map_err(|e| format!("creating the S3 identity devbox-{name}: {e}"))?;
    let env = session::stack_env(cfg, &session::NewSession { name, repo: &slug, token: &token, plugins: &plugins, pubkeys: &pubkeys, s3_secret: &secret });
    pt.create_stack(&format!("dev-{name}"), COMPOSE, &env)?;
    println!("Session {name} created for {slug}.");

    let dir = ssh_dir()?;
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let conf = dir.join("devbox.conf");
    let current = std::fs::read_to_string(&conf).unwrap_or_default();
    session::write_file(&conf, &session::devbox_conf_with(&current, &session::ssh_config_entry(cfg, name), name))?;
    let main_conf = dir.join("config");
    if let Some(updated) = session::ssh_config_including(&std::fs::read_to_string(&main_conf).unwrap_or_default()) {
        session::write_file(&main_conf, &updated)?;
        println!("Added `Include devbox.conf` at the top of {}.", main_conf.display());
    }
    println!("\n  ssh dev-{name}\n\nThe first start clones the repo (or restores it from the bucket) and installs plugins: give it a minute.");
    println!("Logins land in tmux (session \"main\"): a dropped connection leaves claude running; ssh again to re-attach.");
    println!("First time only: run `claude` there and log in with your subscription (it prints a link and asks for a code).");
    Ok(())
}

fn list(cfg: &config::Config) -> Result<(), String> {
    let stacks = portainer::Client::new(cfg)?.list_stacks()?;
    if stacks.is_empty() {
        println!("no sessions");
    }
    for s in &stacks {
        println!("{:<34} {}", s.name.trim_start_matches("dev-"), if s.running { "running" } else { "stopped" });
    }
    println!("{} running, cap {}", running(&stacks), cfg.max_active);
    Ok(())
}

fn stop(cfg: &config::Config, name: &str) -> Result<(), String> {
    let name = validate::session_name(name)?;
    let pt = portainer::Client::new(cfg)?;
    let s = find(&pt.list_stacks()?, name)?.id;
    println!("stopping {name} (its last sync can take up to two minutes)...");
    pt.stop(s)?;
    if find(&pt.list_stacks()?, name)?.running {
        return Err(format!("Portainer still reports {name} as running"));
    }
    println!("{name} stopped");
    Ok(())
}

fn resume(cfg: &config::Config, name: &str) -> Result<(), String> {
    let name = validate::session_name(name)?;
    let pt = portainer::Client::new(cfg)?;
    let stacks = pt.list_stacks()?;
    let s = find(&stacks, name)?;
    if s.running {
        println!("{name} is already running");
        return Ok(());
    }
    session::check_cap(running(&stacks), cfg.max_active)?;
    pt.start(s.id)?;
    println!("{name} started: ssh dev-{name}");
    Ok(())
}

fn token(cfg: &config::Config, name: &str) -> Result<(), String> {
    let name = validate::session_name(name)?;
    let pt = portainer::Client::new(cfg)?;
    let id = find(&pt.list_stacks()?, name)?.id;
    let mut env = pt.stack_env(id)?;
    let repo = env.iter().find(|(k, _)| k == "REPO_URL").map(|(_, v)| v.clone()).ok_or("stack has no REPO_URL")?;
    let slug = validate::repo_slug(&repo)?;
    let token = ask_token(&slug)?;
    for (k, v) in env.iter_mut() {
        if k == "GH_TOKEN" {
            *v = token.clone();
        }
    }
    println!("redeploying {name} with the new token (the session restarts; its state is pushed first)...");
    pt.update_stack(id, COMPOSE, &env)?;
    println!("{name}: token replaced");
    Ok(())
}

fn delete(cfg: &config::Config, name: &str, yes: bool) -> Result<(), String> {
    let name = validate::session_name(name)?;
    let pt = portainer::Client::new(cfg)?;
    let s = find(&pt.list_stacks()?, name)?.id;
    if !yes
        && !dialoguer::Confirm::new()
            .with_prompt(format!("Delete session {name}, its volumes and its S3 identity? (the bucket copy is kept)"))
            .interact()
            .map_err(|e| e.to_string())?
    {
        return Ok(());
    }
    pt.delete(s)?;
    for v in ["work", "state"] {
        if let Err(e) = pt.delete_volume(&format!("dev-{name}-{v}")) {
            eprintln!("warning: {e}");
        }
    }
    if let Err(e) = pt.exec_in_service(S3_PROJECT, "s3", s3::DELETE, &[("N", name)]) {
        eprintln!("warning: S3 identity devbox-{name} not removed: {e}");
    }
    if let Ok(dir) = ssh_dir() {
        let conf = dir.join("devbox.conf");
        if let Ok(current) = std::fs::read_to_string(&conf) {
            let _ = session::write_file(&conf, &session::devbox_conf_without(&current, name));
        }
        // A recreated session has a new host key: forget the old one.
        let _ = std::process::Command::new("ssh-keygen").args(["-R", &format!("[dev-{name}]:2222")]).output();
    }
    println!("{name} deleted. The bucket keeps devbox/{name}/: `devbox create {name}` with the same repo restores from it.");
    println!("To drop it for good, delete the devbox/{name}/ prefix in the s3-admin UI.");
    Ok(())
}
