mod catalog;
mod config;
mod github;
mod portainer;
mod session;
mod validate;

use clap::{Parser, Subcommand};
use std::process::ExitCode;

#[derive(Parser)]
#[command(name = "devbox", about = "Sessions de dev Claude Code")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Crée une session (pile Portainer dev-<nom>)
    Create {
        name: String,
        /// URL ou owner/nom du dépôt GitHub
        #[arg(long)]
        repo: Option<String>,
        /// Plugin plugin@marketplace (répétable)
        #[arg(long = "plugin")]
        plugins: Vec<String>,
    },
    /// Liste les sessions
    List,
    /// Arrête une session
    Stop { name: String },
    /// Relance une session arrêtée
    Resume { name: String },
    /// Supprime une session et son volume
    Delete {
        name: String,
        /// Pas de confirmation
        #[arg(long)]
        yes: bool,
        /// Non implémenté: affiche la commande manuelle
        #[arg(long)]
        purge: bool,
    },
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let res = config::Config::load().and_then(|cfg| match cli.cmd {
        Cmd::Create {
            name,
            repo,
            plugins,
        } => session::create(&cfg, &name, repo, plugins),
        Cmd::List => session::list(&cfg),
        Cmd::Stop { name } => session::stop(&cfg, &name),
        Cmd::Resume { name } => session::resume(&cfg, &name),
        Cmd::Delete { name, yes, purge } => session::delete(&cfg, &name, yes, purge),
    });
    match res {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("erreur: {e}");
            ExitCode::FAILURE
        }
    }
}
