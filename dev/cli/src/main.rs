// ponytail: config/validate are consumed by Tasks 5-6; drop this allow then.
#![allow(dead_code)]
mod config;
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
    Create,
    List,
    Stop,
    Resume,
    Delete,
}

fn main() -> ExitCode {
    Cli::parse();
    eprintln!("not implemented yet");
    ExitCode::FAILURE
}
