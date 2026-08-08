use std::fs::File;
use std::io::Write;
use std::process::{Command, Stdio};

fn g_command() -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_g"));
    command.current_dir(env!("CARGO_MANIFEST_DIR"));
    command
}

#[test]
fn help_describes_current_context_options() {
    let output = g_command()
        .arg("--help")
        .output()
        .expect("g --help should run");

    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("-B N|start"));
    assert!(stdout.contains("Set characters after match"));
}

#[test]
fn stdin_search_uses_the_search_output_contract() {
    let mut child = g_command()
        .arg("-C")
        .arg("0")
        .arg("needle")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("g stdin search should run");

    child
        .stdin
        .as_mut()
        .expect("stdin should be piped")
        .write_all(b"before\nneedle\nafter\n")
        .expect("test input should be written");

    let output = child.wait_with_output().expect("g should finish");
    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("stdin://pipe"));
    assert!(stdout.contains("needle"));
}

#[test]
fn audit_reports_extensions_for_a_path() {
    let output = g_command()
        .args(["--audit", "src"])
        .output()
        .expect("g audit should run");

    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("---- audit ----"));
    assert!(stdout.contains("ext"));
    assert!(stdout.contains("rs"));
}

#[test]
fn missing_paths_fail_instead_of_falling_back_to_the_current_directory() {
    let output = g_command()
        .args([
            "--counts",
            "needle",
            "/tmp/g-review-path-that-does-not-exist",
        ])
        .output()
        .expect("g should run");

    assert_eq!(output.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("path does not exist"));
}

#[test]
fn duplicate_audit_roots_are_counted_once() {
    let single = g_command()
        .args(["--audit", "src"])
        .output()
        .expect("single-root audit should run");
    let duplicate = g_command()
        .args(["--audit", "src", "src"])
        .output()
        .expect("duplicate-root audit should run");

    fn total(output: &[u8]) -> String {
        String::from_utf8_lossy(output)
            .lines()
            .find(|line| line.starts_with("total:"))
            .expect("audit should print a total")
            .to_string()
    }

    assert_eq!(total(&single.stdout), total(&duplicate.stdout));
}

#[test]
fn empty_pattern_matches_stdin_lines() {
    let mut child = g_command()
        .arg("-C")
        .arg("0")
        .arg("")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("g stdin search should run");

    child
        .stdin
        .as_mut()
        .expect("stdin should be piped")
        .write_all(b"alpha\nbeta\n")
        .expect("test input should be written");

    let output = child.wait_with_output().expect("g should finish");
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("stdin://pipe"));
}

#[cfg(unix)]
#[test]
fn regular_file_stdin_does_not_override_default_path_search() {
    let stdin_file = File::open("/dev/null").expect("/dev/null should exist");
    let output = g_command()
        .arg("-C")
        .arg("0")
        .arg("fn main")
        .stdin(Stdio::from(stdin_file))
        .output()
        .expect("g should run");

    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("src/main.rs"));
    assert!(!stdout.contains("stdin://pipe"));
}

#[test]
fn unicode_match_output_highlights_only_the_match() {
    let mut child = g_command()
        .arg("-C")
        .arg("0")
        .arg("x")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("g stdin search should run");

    child
        .stdin
        .as_mut()
        .expect("stdin should be piped")
        .write_all("éxabc\n".as_bytes())
        .expect("test input should be written");

    let output = child.wait_with_output().expect("g should finish");
    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("x"));
    assert!(!stdout.contains("xa"));
}
