#[derive(Debug, PartialEq, Eq)]
pub struct Options {
    pub audit: bool,
    pub sizes: bool,
    pub hidden: bool,
    pub literal: bool,
    pub no_ignore: bool,
    pub binary: bool,
    pub counts: bool,
    pub case_sensitive: bool,
    pub ext_filter_mode: String,
    pub before: usize,
    pub before_to_line_start: bool,
    pub after: usize,
    pub verbose: bool,
    pub pattern: String,
    pub paths: Vec<String>,
    pub use_stdin: bool,
}

pub fn parse_args() -> Options {
    parse_args_from(std::env::args().collect())
}

fn stdin_is_pipe() -> bool {
    use std::io::IsTerminal;

    if std::io::stdin().is_terminal() {
        return false;
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::FileTypeExt;

        std::fs::metadata("/proc/self/fd/0")
            .map(|metadata| metadata.file_type().is_fifo())
            .unwrap_or(false)
    }

    #[cfg(not(unix))]
    {
        false
    }
}

pub(crate) fn parse_args_from(args: Vec<String>) -> Options {
    let mut audit = false;
    let mut sizes = false;
    let mut hidden = false;
    let mut literal = false;
    let mut no_ignore = false;
    let mut binary = false;
    let mut counts = false;
    let mut case_sensitive = false;
    let mut ext_filter_mode = "all".to_string();
    let mut before = 10;
    let mut before_to_line_start = false;
    let mut after = 10;
    let mut a_given = false;
    let mut b_given = false;
    let mut verbose = false;
    let mut u_count = 0;
    let mut positionals = Vec::new();

    let mut i = 1;
    while i < args.len() {
        let arg = &args[i];
        if arg == "--" {
            positionals.extend(args[i + 1..].iter().cloned());
            break;
        } else if arg.starts_with("--") {
            match arg.as_str() {
                "--audit" => audit = true,
                "--sizes" => sizes = true,
                "--hidden" => hidden = true,
                "--literal" => literal = true,
                "--no_ignore" | "--no-ignore" => no_ignore = true,
                "--binary" | "--text" => binary = true,
                "--counts" => counts = true,
                "--case-sensitive" => case_sensitive = true,
                "--whitelist" => ext_filter_mode = "whitelist".to_string(),
                "--blacklist" => ext_filter_mode = "blacklist".to_string(),
                "--verbose" => verbose = true,
                "--help" => {
                    print_help();
                    std::process::exit(0);
                }
                _ => {
                    eprintln!("Error: unknown option {}", arg);
                    print_help();
                    std::process::exit(2);
                }
            }
        } else if arg.starts_with('-') && arg != "-" {
            let chars: Vec<char> = arg.chars().skip(1).collect();
            let mut char_idx = 0;
            while char_idx < chars.len() {
                let ch = chars[char_idx];
                match ch {
                    'u' => u_count += 1,
                    'l' => literal = true,
                    'v' => verbose = true,
                    'h' => {
                        print_help();
                        std::process::exit(0);
                    }
                    'B' | 'A' | 'C' => {
                        let val = if char_idx + 1 < chars.len() {
                            let attached: String = chars[char_idx + 1..].iter().collect();
                            char_idx = chars.len();
                            attached
                        } else if i + 1 < args.len() {
                            i += 1;
                            args[i].clone()
                        } else {
                            eprintln!("Error: option -{} requires an argument", ch);
                            std::process::exit(2);
                        };

                        match ch {
                            'B' => {
                                if val.eq_ignore_ascii_case("start") {
                                    before = 0;
                                    before_to_line_start = true;
                                } else if let Ok(n) = val.parse::<usize>() {
                                    before = n;
                                    before_to_line_start = false;
                                } else {
                                    eprintln!("Error: invalid value for -B: {}", val);
                                    std::process::exit(2);
                                }
                                b_given = true;
                            }
                            'A' => {
                                if let Ok(n) = val.parse::<usize>() {
                                    after = n;
                                } else {
                                    eprintln!("Error: invalid value for -A: {}", val);
                                    std::process::exit(2);
                                }
                                a_given = true;
                            }
                            'C' => {
                                if let Ok(n) = val.parse::<usize>() {
                                    before = n;
                                    after = n;
                                    before_to_line_start = false;
                                } else {
                                    eprintln!("Error: invalid value for -C: {}", val);
                                    std::process::exit(2);
                                }
                                a_given = true;
                                b_given = true;
                            }
                            _ => unreachable!(),
                        }
                    }
                    _ => {
                        eprintln!("Error: unknown option -{}", ch);
                        print_help();
                        std::process::exit(2);
                    }
                }
                char_idx += 1;
            }
        } else {
            positionals.push(arg.clone());
        }
        i += 1;
    }

    if args.len() == 1 {
        audit = true;
    }

    if u_count >= 1 {
        hidden = true;
    }
    if u_count >= 2 {
        no_ignore = true;
    }
    if u_count >= 3 {
        binary = true;
    }

    if a_given && !b_given {
        before = 0;
    }
    if b_given && !a_given {
        after = 0;
    }

    let pattern = if !audit {
        if positionals.is_empty() {
            eprintln!("Error: PATTERN is required for search mode.");
            print_help();
            std::process::exit(2);
        }
        positionals.remove(0)
    } else {
        String::new()
    };

    let mut paths = positionals;
    let mut use_stdin = false;
    if paths.is_empty() {
        if !audit && stdin_is_pipe() {
            use_stdin = true;
        } else {
            paths.push(".".to_string());
        }
    }

    Options {
        audit,
        sizes,
        hidden,
        literal,
        no_ignore,
        binary,
        counts,
        case_sensitive,
        ext_filter_mode,
        before,
        before_to_line_start,
        after,
        verbose,
        pattern,
        paths,
        use_stdin,
    }
}

pub fn print_help() {
    println!(
        "NAME
    g - a fast search and audit tool rewritten in Rust

SYNOPSIS
    g [OPTIONS] PATTERN [PATH...]
    g --audit [OPTIONS] [PATH...]

DESCRIPTION
    g is a native Rust replacement for the g search tool. It performs extremely
    fast recursive directory walking and regex searches, extracting matching
    tokens with a custom character context window.

OPTIONS
    -B N|start
        Set characters before match (default: 10). Use 'start' to show context
        from the start of the line.
    -A N
        Set characters after match (default: 10).
    -C N
        Set both -B and -A to N.
    -l, --literal
        Treat PATTERN as a literal string instead of a regular expression.
    --hidden
        Search hidden files and directories.
    --no_ignore, --no-ignore
        Do not respect ignore files (.gitignore, .ignore, etc.).
    --binary
        Search binary files (treat them as text).
    --counts
        Output only per-file match counts (tsv: count<TAB>path).
    --case-sensitive
        Force case-sensitive search (default is case-insensitive).
    --whitelist
        Only scan extensions in the hardcoded list.
    --blacklist
        Scan everything EXCEPT extensions in the hardcoded list.
    -u
        Include hidden files (equivalent to --hidden).
    -uu
        Include hidden + no-ignore (equivalent to --hidden --no-ignore).
    -uuu
        Include hidden + no-ignore + binary (equivalent to --hidden --no-ignore --binary).
    -v
        Verbose mode: print scan summary totals at the end of the run.
    --audit
        Run in fast audit mode (counts files by extension).
    --sizes
        Include logical apparent size totals per extension (audit mode only).
    -h, --help
        Display this help text.

OPERATION
    When no PATH is specified, g searches the current directory '.'. If stdin
    is a pipe and no PATH is specified, it reads from stdin.

EXAMPLES
    Search for 'fn main' in the current directory:
        g \"fn main\"
    Search literally for 'foo.bar' in src/ and tests/:
        g -l \"foo.bar\" src/ tests/
    Audit the current directory:
        g --audit

FILES
    g.match_files.log
        Written to the executable's directory or G_MATCH_FILES_LOG path,
        containing a sorted TSV list of matching files and counts.
    g.skipped.log
        Written to the executable's directory or G_SKIP_LOG path,
        containing a list of skipped binary files.

PATHS
    Paths specified as positional arguments will restrict the search or audit
    to those directories/files.

SECURITY NOTES
    g only reads files and does not modify any system files. It is safe to run
    on any directory.

EXIT STATUS
    0   Matches found (search mode) or audit completed successfully.
    1   No matches found (search mode).
    2   Invalid arguments or general error.

AUTHORS
    Terrydaktal <9lewis9@gmail.com>"
    );
}

#[cfg(test)]
mod tests {
    use super::{parse_args_from, Options};

    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_string()).collect()
    }

    #[test]
    fn no_arguments_default_to_audit() {
        let parsed = parse_args_from(args(&["g"]));
        assert!(parsed.audit);
        assert_eq!(parsed.paths, vec!["."]);
    }

    #[test]
    fn one_sided_context_options_zero_the_other_side() {
        let parsed = parse_args_from(args(&["g", "-A", "4", "needle", "file.txt"]));
        assert_eq!(parsed.after, 4);
        assert_eq!(parsed.before, 0);

        let parsed = parse_args_from(args(&["g", "-B", "6", "needle", "file.txt"]));
        assert_eq!(parsed.before, 6);
        assert_eq!(parsed.after, 0);
    }

    #[test]
    fn context_and_short_flags_are_preserved() {
        let parsed = parse_args_from(args(&["g", "-uuu", "-Bstart", "-C2", "needle", "file.txt"]));
        assert_eq!(
            parsed,
            Options {
                audit: false,
                sizes: false,
                hidden: true,
                literal: false,
                no_ignore: true,
                binary: true,
                counts: false,
                case_sensitive: false,
                ext_filter_mode: "all".to_string(),
                before: 2,
                before_to_line_start: false,
                after: 2,
                verbose: false,
                pattern: "needle".to_string(),
                paths: vec!["file.txt".to_string()],
                use_stdin: false,
            }
        );
    }
}
