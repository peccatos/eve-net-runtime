use anyhow::{anyhow, Context, Result};
use std::process::Command;
use tracing::{debug, info, warn};

#[derive(Debug, Clone)]
pub struct Executor {
    apply: bool,
}

impl Executor {
    pub fn new(apply: bool) -> Self {
        Self { apply }
    }

    pub fn is_apply(&self) -> bool {
        self.apply
    }

    pub fn run<I, S>(&self, program: &str, args: I) -> Result<()>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let args_vec: Vec<String> = args
            .into_iter()
            .map(|arg| arg.as_ref().to_string())
            .collect();

        if !self.apply {
            info!("[dry-run] {} {}", program, args_vec.join(" "));
            return Ok(());
        }

        debug!("exec: {} {}", program, args_vec.join(" "));
        let status = Command::new(program)
            .args(&args_vec)
            .status()
            .with_context(|| format!("failed to spawn {}", program))?;

        if !status.success() {
            return Err(anyhow!("command failed: {} {}", program, args_vec.join(" ")));
        }

        Ok(())
    }

    pub fn run_allow_fail<I, S>(&self, program: &str, args: I) -> bool
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let args_vec: Vec<String> = args
            .into_iter()
            .map(|arg| arg.as_ref().to_string())
            .collect();

        if !self.apply {
            info!("[dry-run] {} {}", program, args_vec.join(" "));
            return true;
        }

        debug!("exec optional: {} {}", program, args_vec.join(" "));
        match Command::new(program).args(&args_vec).status() {
            Ok(status) if status.success() => true,
            Ok(status) => {
                warn!(code = ?status.code(), command = %format!("{} {}", program, args_vec.join(" ")), "optional command failed");
                false
            }
            Err(err) => {
                warn!(error = %err, command = %format!("{} {}", program, args_vec.join(" ")), "failed to spawn optional command");
                false
            }
        }
    }

    pub fn capture<I, S>(&self, program: &str, args: I) -> Result<String>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let args_vec: Vec<String> = args
            .into_iter()
            .map(|arg| arg.as_ref().to_string())
            .collect();

        debug!("capture: {} {}", program, args_vec.join(" "));
        let output = Command::new(program)
            .args(&args_vec)
            .output()
            .with_context(|| format!("failed to spawn {}", program))?;

        if !output.status.success() {
            return Err(anyhow!("command failed: {} {}", program, args_vec.join(" ")));
        }

        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    pub fn capture_or_empty<I, S>(&self, program: &str, args: I) -> String
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        self.capture(program, args).unwrap_or_default()
    }

    pub fn status<I, S>(&self, program: &str, args: I) -> bool
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let args_vec: Vec<String> = args
            .into_iter()
            .map(|arg| arg.as_ref().to_string())
            .collect();

        Command::new(program)
            .args(&args_vec)
            .status()
            .map(|status| status.success())
            .unwrap_or(false)
    }
}
