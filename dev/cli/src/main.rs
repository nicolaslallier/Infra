//! devbox: Claude Code dev sessions, one Portainer stack each.
//! See CLAUDE.md "Dev sessions" in the Infra repo.
mod catalog;
mod config;
mod github;
mod portainer;
mod session;
mod validate;

use clap::{Parser, Subcommand};

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
    /// Delete a session's stack and volume (the bucket copy is kept)
    Delete {
        name: String,
        /// Don't ask for confirmation
        #[arg(long)]
        yes: bool,
    },
}

const COMPOSE: &str = include_str!("../../session.compose.yml");

fn main() {
    let cli = Cli::parse();
    let result = config::Config::load().and_then(|cfg| match cli.cmd {
        Cmd::Create { name, repo, plugins } => create(&cfg, &name, repo, plugins),
        Cmd::List => list(&cfg),
        Cmd::Stop { name } => stop(&cfg, &name),
        Cmd::Resume { name } => resume(&cfg, &name),
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

fn find<'a>(stacks: &'a [portainer::Stack], name: &str) -> Result<&'a portainer::Stack, String> {
    let stack = format!("dev-{}", validate::session_name(name)?);
    stacks.iter().find(|s| s.name == stack).ok_or_else(|| format!("no session {name}"))
}

fn create(cfg: &config::Config, name: &str, repo: Option<String>, mut plugins: Vec<String>) -> Result<(), String> {
    let name = validate::session_name(name)?;
    let pubkey = std::fs::read_to_string(&cfg.pubkey_path).map_err(|e| format!("{}: {e}", cfg.pubkey_path.display()))?;
    let pt = portainer::Client::new(cfg)?;
    let stacks = pt.list_stacks()?;
    if stacks.iter().any(|s| s.name == format!("dev-{name}")) {
        return Err(format!("session {name} already exists (devbox resume {name}, or devbox delete {name})"));
    }
    session::check_cap(running(&stacks), cfg.max_active)?;

    let repo = match repo {
        Some(r) => r,
        None => dialoguer::Input::new().with_prompt("GitHub repository").interact_text().map_err(|e| e.to_string())?,
    };
    let slug = validate::repo_slug(&repo)?;
    let token = dialoguer::Password::new()
        .with_prompt(format!("GitHub token for {slug} only (fine-grained, this one repository)"))
        .interact()
        .map_err(|e| e.to_string())?;
    if !github::main_is_protected(&slug, &token)? {
        return Err(format!("main of {slug} is not protected: turn on branch protection for main first (Settings -> Branches)"));
    }

    if plugins.is_empty() {
        let all = catalog::fetch_all(&cfg.catalogs)?;
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

    let env = session::stack_env(cfg, name, &slug, &token, &plugins, &pubkey);
    pt.create_stack(&format!("dev-{name}"), COMPOSE, &env)?;
    println!("Session {name} created for {slug}.");

    let home = directories::BaseDirs::new().ok_or("no home directory")?.home_dir().to_path_buf();
    let path = home.join(".ssh").join("config");
    let current = std::fs::read_to_string(&path).unwrap_or_default();
    if let Some(updated) = session::ssh_config_with(&current, &session::ssh_config_entry(cfg, name), name) {
        std::fs::create_dir_all(home.join(".ssh")).map_err(|e| e.to_string())?;
        std::fs::write(&path, updated).map_err(|e| format!("{}: {e}", path.display()))?;
        println!("Added Host dev-{name} to {}.", path.display());
    }
    println!("\n  ssh dev-{name}\n\nThe first start clones the repo and installs plugins: give it a minute.");
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

fn delete(cfg: &config::Config, name: &str, yes: bool) -> Result<(), String> {
    let pt = portainer::Client::new(cfg)?;
    let s = find(&pt.list_stacks()?, name)?.id;
    if !yes
        && !dialoguer::Confirm::new()
            .with_prompt(format!("Delete session {name} and its volume? (the bucket copy is kept)"))
            .interact()
            .map_err(|e| e.to_string())?
    {
        return Ok(());
    }
    pt.delete(s)?;
    if let Err(e) = pt.delete_volume(&format!("dev-{name}-work")) {
        eprintln!("warning: {e}");
    }
    println!("{name} deleted. The bucket keeps devbox/{name}/: `devbox create {name}` restores from it.");
    println!("To drop it for good, delete the devbox/{name}/ prefix in the s3-admin UI.");
    Ok(())
}
