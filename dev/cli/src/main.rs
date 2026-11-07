//! devbox: Claude Code dev sessions, one Portainer stack each.
//! See CLAUDE.md "Dev sessions" in the Infra repo.
mod config;
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

fn main() {
    let cli = Cli::parse();
    let result: Result<(), String> = match cli.cmd {
        Cmd::Create { .. } | Cmd::List | Cmd::Stop { .. } | Cmd::Resume { .. } | Cmd::Delete { .. } => todo!(),
    };
    if let Err(e) = result {
        eprintln!("devbox: {e}");
        std::process::exit(1);
    }
}
