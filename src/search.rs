use crate::cli::Options;
use crate::file_policy::{ext_of, is_hidden_path, resolve_roots, FILTER_EXTS};
use ignore::{DirEntry, ParallelVisitor, ParallelVisitorBuilder, WalkBuilder, WalkState};
use std::collections::HashMap;
use std::io::{IsTerminal, Read, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

const RED: &str = "\x1b[31m";
const GREEN: &str = "\x1b[32m";
const LIGHT_BLUE: &str = "\x1b[38;2;122;218;247m";
const RESET: &str = "\x1b[0m";

fn preprocess_pattern(pat: &str) -> String {
    let mut result = String::new();
    let chars: Vec<char> = pat.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '\\' && i + 1 < chars.len() && chars[i + 1] == 'x' {
            let mut bs_count = 0;
            let mut j = i;
            while j > 0 && chars[j - 1] == '\\' {
                bs_count += 1;
                j -= 1;
            }
            let is_escaped = bs_count % 2 == 1;

            let mut follows_hex_or_brace = false;
            if i + 2 < chars.len() {
                let next = chars[i + 2];
                if next.is_ascii_hexdigit() || next == '{' {
                    follows_hex_or_brace = true;
                }
            }

            if !is_escaped && !follows_hex_or_brace {
                result.push_str(r"\b\w+\b");
                i += 2;
                continue;
            }
        }
        result.push(chars[i]);
        i += 1;
    }
    result
}

struct SnippetRequest<'a> {
    all_lines: &'a [&'a str],
    line_no: usize,
    start_b: usize,
    end_b: usize,
    before: usize,
    after: usize,
    ctx_lines: usize,
    before_to_line_start: bool,
    colored: bool,
}

fn format_snippet_direct(request: SnippetRequest<'_>) -> String {
    let SnippetRequest {
        all_lines,
        line_no,
        start_b,
        end_b,
        before,
        after,
        ctx_lines,
        before_to_line_start,
        colored,
    } = request;
    let start_ln = line_no.saturating_sub(ctx_lines).max(1);
    let end_ln = std::cmp::min(all_lines.len(), line_no.saturating_add(ctx_lines));
    let line_text = all_lines[line_no - 1];

    let before_match = if before_to_line_start {
        line_text[..start_b].to_string()
    } else {
        collect_before(all_lines, line_no, start_b, before, start_ln)
    };
    let match_part = line_text[start_b..end_b].to_string();
    let after_match = collect_after(all_lines, line_no, end_b, after, end_ln);

    if colored {
        format!(
            "{}{}{}{}{}",
            before_match, RED, match_part, RESET, after_match
        )
    } else {
        format!("{}{}{}", before_match, match_part, after_match)
    }
}

fn byte_start_for_last_chars(text: &str, count: usize) -> usize {
    if count == 0 {
        return text.len();
    }
    text.char_indices()
        .rev()
        .nth(count - 1)
        .map(|(index, _)| index)
        .unwrap_or(0)
}

fn byte_end_for_first_chars(text: &str, count: usize) -> usize {
    if count == 0 {
        return 0;
    }
    text.char_indices()
        .nth(count)
        .map(|(index, _)| index)
        .unwrap_or(text.len())
}

fn collect_before(
    all_lines: &[&str],
    line_no: usize,
    start_b: usize,
    count: usize,
    first_line: usize,
) -> String {
    let mut remaining = count;
    let mut chunks = Vec::new();
    let mut current_line = line_no - 1;
    let prefix = &all_lines[current_line][..start_b];
    let prefix_start = byte_start_for_last_chars(prefix, remaining);
    let taken = prefix[prefix_start..].chars().count();
    chunks.push(prefix[prefix_start..].to_string());
    remaining = remaining.saturating_sub(taken);

    while remaining > 0 && current_line + 1 > first_line {
        chunks.push(" ".to_string());
        remaining -= 1;
        current_line -= 1;
        let text = all_lines[current_line];
        let start = byte_start_for_last_chars(text, remaining);
        let part = &text[start..];
        let taken = part.chars().count();
        chunks.push(part.to_string());
        remaining = remaining.saturating_sub(taken);
    }

    chunks.reverse();
    chunks.concat()
}

fn collect_after(
    all_lines: &[&str],
    line_no: usize,
    end_b: usize,
    count: usize,
    last_line: usize,
) -> String {
    let mut remaining = count;
    let mut chunks = Vec::new();
    let mut current_line = line_no - 1;
    let suffix = &all_lines[current_line][end_b..];
    let end = byte_end_for_first_chars(suffix, remaining);
    let part = &suffix[..end];
    let taken = part.chars().count();
    chunks.push(part.to_string());
    remaining = remaining.saturating_sub(taken);

    while remaining > 0 && current_line + 1 < last_line {
        chunks.push(" ".to_string());
        remaining -= 1;
        current_line += 1;
        let text = all_lines[current_line];
        let end = byte_end_for_first_chars(text, remaining);
        let part = &text[..end];
        let taken = part.chars().count();
        chunks.push(part.to_string());
        remaining = remaining.saturating_sub(taken);
    }

    chunks.concat()
}

struct FileMatch {
    line_no: usize,
    start_b: usize,
    end_b: usize,
}

#[derive(Default, Clone)]
struct ExtStats {
    seen: u64,
    attempted: u64,
    hidden_skipped: u64,
    blacklisted: u64,
    skipped: u64,
    failed: u64,
}

struct LocalSearchStats {
    seen: u64,
    attempted: u64,
    hidden_skipped: u64,
    blacklisted: u64,
    skipped: u64,
    failed: u64,
    ext_stats: HashMap<String, ExtStats>,
}

#[derive(Default)]
struct SearchStats {
    seen: u64,
    attempted: u64,
    hidden_skipped: u64,
    blacklisted: u64,
    skipped: u64,
    failed: u64,
    ext_stats: HashMap<String, ExtStats>,
}

struct SearchVisitor {
    matcher: regex::Regex,
    before: usize,
    after: usize,
    ctx_lines: usize,
    before_to_line_start: bool,
    counts_only: bool,
    match_empty_pattern: bool,
    search_binary: bool,
    search_hidden: bool,
    ext_filter_mode: String,
    whitelist_set: Arc<std::collections::HashSet<String>>,

    global_match_no: Arc<AtomicUsize>,
    shared_stats: Arc<Mutex<SearchStats>>,
    shared_match_files: Arc<Mutex<HashMap<String, usize>>>,
    shared_skipped_logs: Arc<Mutex<Vec<String>>>,
    cancelled: Arc<std::sync::atomic::AtomicBool>,

    local_stats: LocalSearchStats,
}

impl ParallelVisitor for SearchVisitor {
    fn visit(&mut self, entry: Result<DirEntry, ignore::Error>) -> WalkState {
        if self.cancelled.load(Ordering::Relaxed) {
            return WalkState::Quit;
        }

        let entry = match entry {
            Ok(e) => e,
            Err(_) => {
                self.local_stats.failed += 1;
                return WalkState::Continue;
            }
        };

        if !entry.file_type().map(|ft| ft.is_file()).unwrap_or(false) {
            return WalkState::Continue;
        }

        let path = entry.path();
        let ext = ext_of(path);

        self.local_stats.seen += 1;
        let ext_entry = self.local_stats.ext_stats.entry(ext.clone()).or_default();
        ext_entry.seen += 1;

        let is_hidden = is_hidden_path(path);
        if !self.search_hidden && is_hidden {
            self.local_stats.hidden_skipped += 1;
            ext_entry.hidden_skipped += 1;
            return WalkState::Continue;
        }

        let is_wl = self.whitelist_set.contains(&ext);
        let allowed = match self.ext_filter_mode.as_str() {
            "whitelist" => is_wl,
            "blacklist" => !is_wl,
            _ => true,
        };

        if !allowed {
            self.local_stats.blacklisted += 1;
            ext_entry.blacklisted += 1;
            return WalkState::Continue;
        }

        let bytes = match std::fs::read(path) {
            Ok(b) => b,
            Err(_) => {
                self.local_stats.failed += 1;
                ext_entry.failed += 1;
                return WalkState::Continue;
            }
        };

        let content_str: String;
        let content_cow: std::borrow::Cow<str>;

        let all_lines: Vec<&str> = if ext == "pdf" {
            match pdf_extract::extract_text_from_mem(&bytes) {
                Ok(text) => {
                    content_str = text;
                    content_str.lines().collect()
                }
                Err(_) => {
                    self.local_stats.failed += 1;
                    ext_entry.failed += 1;
                    return WalkState::Continue;
                }
            }
        } else {
            let is_binary = bytes.contains(&0);
            if is_binary && !self.search_binary {
                self.local_stats.skipped += 1;
                ext_entry.skipped += 1;
                if let Ok(mut logs) = self.shared_skipped_logs.lock() {
                    logs.push(path.to_string_lossy().to_string());
                }
                return WalkState::Continue;
            }
            content_cow = String::from_utf8_lossy(&bytes);
            content_cow.lines().collect()
        };

        self.local_stats.attempted += 1;
        ext_entry.attempted += 1;

        let mut file_matches = Vec::new();
        let mut match_count = 0;
        for (idx, line) in all_lines.iter().enumerate() {
            let line_no = idx + 1;
            if self.match_empty_pattern {
                match_count += 1;
                if !self.counts_only {
                    file_matches.push(FileMatch {
                        line_no,
                        start_b: 0,
                        end_b: 0,
                    });
                }
                continue;
            }
            for mat in self.matcher.find_iter(line) {
                let start_b = mat.start();
                let end_b = mat.end();
                if start_b != end_b {
                    match_count += 1;
                    if !self.counts_only {
                        file_matches.push(FileMatch {
                            line_no,
                            start_b,
                            end_b,
                        });
                    }
                }
            }
        }

        if match_count > 0 {
            let path_str = path.to_string_lossy().to_string();
            if let Ok(mut mf) = self.shared_match_files.lock() {
                mf.insert(path_str.clone(), match_count);
            }

            if !self.counts_only {
                let colored =
                    std::io::stdout().is_terminal() && std::env::var_os("NO_COLOR").is_none();
                let mut rendered = Vec::with_capacity(file_matches.len());
                for m in &file_matches {
                    let snippet = format_snippet_direct(SnippetRequest {
                        all_lines: &all_lines,
                        line_no: m.line_no,
                        start_b: m.start_b,
                        end_b: m.end_b,
                        before: self.before,
                        after: self.after,
                        ctx_lines: self.ctx_lines,
                        before_to_line_start: self.before_to_line_start,
                        colored,
                    });
                    let path_link = if !colored {
                        path_str.clone()
                    } else if path_str.starts_with('/') {
                        format!(
                            "\x1b]8;;file://{}\x1b\\{}\x1b]8;;\x1b\\",
                            path_str, path_str
                        )
                    } else if let Ok(cwd) = std::env::current_dir() {
                        let clean_path = path_str.trim_start_matches("./");
                        format!(
                            "\x1b]8;;file://{}/{}\x1b\\{}\x1b]8;;\x1b\\",
                            cwd.display(),
                            clean_path,
                            path_str
                        )
                    } else {
                        path_str.clone()
                    };
                    rendered.push((path_link, m.line_no, snippet));
                }
                let mut stdout = std::io::stdout().lock();
                for (path_link, line_no, snippet) in rendered {
                    let current_match_no = self.global_match_no.fetch_add(1, Ordering::Relaxed) + 1;
                    let green = if colored { GREEN } else { "" };
                    let light_blue = if colored { LIGHT_BLUE } else { "" };
                    let reset = if colored { RESET } else { "" };
                    if writeln!(
                        stdout,
                        "{}{}{} {}{} {}:{}{}",
                        green,
                        current_match_no,
                        reset,
                        light_blue,
                        path_link,
                        line_no,
                        reset,
                        snippet
                    )
                    .is_err()
                    {
                        self.cancelled.store(true, Ordering::Relaxed);
                        return WalkState::Quit;
                    }
                }
            } else {
                self.global_match_no
                    .fetch_add(match_count, Ordering::Relaxed);
            }
        }

        WalkState::Continue
    }
}

impl Drop for SearchVisitor {
    fn drop(&mut self) {
        if let Ok(mut stats) = self.shared_stats.lock() {
            stats.seen += self.local_stats.seen;
            stats.attempted += self.local_stats.attempted;
            stats.hidden_skipped += self.local_stats.hidden_skipped;
            stats.blacklisted += self.local_stats.blacklisted;
            stats.skipped += self.local_stats.skipped;
            stats.failed += self.local_stats.failed;

            for (ext, s) in &self.local_stats.ext_stats {
                let entry = stats.ext_stats.entry(ext.clone()).or_default();
                entry.seen += s.seen;
                entry.attempted += s.attempted;
                entry.hidden_skipped += s.hidden_skipped;
                entry.blacklisted += s.blacklisted;
                entry.skipped += s.skipped;
                entry.failed += s.failed;
            }
        }
    }
}

struct SearchVisitorBuilder {
    matcher: regex::Regex,
    before: usize,
    after: usize,
    ctx_lines: usize,
    before_to_line_start: bool,
    counts_only: bool,
    match_empty_pattern: bool,
    search_binary: bool,
    search_hidden: bool,
    ext_filter_mode: String,
    whitelist_set: Arc<std::collections::HashSet<String>>,

    global_match_no: Arc<AtomicUsize>,
    shared_stats: Arc<Mutex<SearchStats>>,
    shared_match_files: Arc<Mutex<HashMap<String, usize>>>,
    shared_skipped_logs: Arc<Mutex<Vec<String>>>,
    cancelled: Arc<std::sync::atomic::AtomicBool>,
}

impl<'s> ParallelVisitorBuilder<'s> for SearchVisitorBuilder {
    fn build(&mut self) -> Box<dyn ParallelVisitor> {
        Box::new(SearchVisitor {
            matcher: self.matcher.clone(),
            before: self.before,
            after: self.after,
            ctx_lines: self.ctx_lines,
            before_to_line_start: self.before_to_line_start,
            counts_only: self.counts_only,
            match_empty_pattern: self.match_empty_pattern,
            search_binary: self.search_binary,
            search_hidden: self.search_hidden,
            ext_filter_mode: self.ext_filter_mode.clone(),
            whitelist_set: self.whitelist_set.clone(),

            global_match_no: self.global_match_no.clone(),
            shared_stats: self.shared_stats.clone(),
            shared_match_files: self.shared_match_files.clone(),
            shared_skipped_logs: self.shared_skipped_logs.clone(),
            cancelled: self.cancelled.clone(),

            local_stats: LocalSearchStats {
                seen: 0,
                attempted: 0,
                hidden_skipped: 0,
                blacklisted: 0,
                skipped: 0,
                failed: 0,
                ext_stats: HashMap::new(),
            },
        })
    }
}

fn get_log_paths() -> (Option<PathBuf>, Option<PathBuf>) {
    let match_files_path = if let Ok(val) = std::env::var("G_MATCH_FILES_LOG") {
        if !val.is_empty() {
            Some(PathBuf::from(val))
        } else {
            None
        }
    } else if let Ok(mut exe) = std::env::current_exe() {
        exe.pop();
        Some(exe.join("g.match_files.log"))
    } else {
        Some(PathBuf::from("g.match_files.log"))
    };

    let skipped_log_path = if let Ok(val) = std::env::var("G_SKIP_LOG") {
        if !val.is_empty() {
            Some(PathBuf::from(val))
        } else {
            None
        }
    } else if let Ok(mut exe) = std::env::current_exe() {
        exe.pop();
        Some(exe.join("g.skipped.log"))
    } else {
        Some(PathBuf::from("g.skipped.log"))
    };

    (match_files_path, skipped_log_path)
}

pub fn run(options: &Options) -> Result<(), Box<dyn std::error::Error>> {
    let regex_pattern = if options.literal {
        regex::escape(&options.pattern)
    } else {
        preprocess_pattern(&options.pattern)
    };

    let mut r_builder = regex::RegexBuilder::new(&regex_pattern);
    r_builder.case_insensitive(!options.case_sensitive);
    let matcher = match r_builder.build() {
        Ok(m) => m,
        Err(e) => {
            eprintln!("Error: invalid regex pattern '{}': {}", options.pattern, e);
            std::process::exit(2);
        }
    };

    let ctx_lines = options
        .before
        .saturating_add(options.after)
        .saturating_add(20);
    let global_match_no = Arc::new(AtomicUsize::new(0));
    let match_empty_pattern = options.pattern.is_empty();

    if options.use_stdin {
        let match_count = search_stdin(
            &matcher,
            options.before,
            options.after,
            ctx_lines,
            options.before_to_line_start,
            options.counts,
            match_empty_pattern,
        );
        if match_count > 0 {
            std::process::exit(0);
        } else {
            std::process::exit(1);
        }
    }

    let shared_stats = Arc::new(Mutex::new(SearchStats::default()));
    let shared_match_files = Arc::new(Mutex::new(HashMap::new()));
    let shared_skipped_logs = Arc::new(Mutex::new(Vec::new()));

    let valid_paths = match resolve_roots(&options.paths) {
        Ok(paths) => paths,
        Err(error) => {
            eprintln!("Error: {}", error);
            std::process::exit(2);
        }
    };

    let mut builder = WalkBuilder::new(&valid_paths[0]);
    for p in valid_paths.iter().skip(1) {
        builder.add(p);
    }

    builder.hidden(!options.hidden && !options.verbose);
    if options.no_ignore {
        builder.ignore(false);
        builder.git_ignore(false);
        builder.git_global(false);
        builder.git_exclude(false);
        builder.parents(false);
    } else {
        builder.ignore(true);
        builder.git_ignore(true);
        builder.git_global(true);
        builder.git_exclude(true);
        builder.parents(true);
    }

    let whitelist_set: Arc<std::collections::HashSet<String>> =
        Arc::new(FILTER_EXTS.iter().map(|s| s.to_string()).collect());
    let cancelled = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let walk = builder.build_parallel();
    let mut visitor = SearchVisitorBuilder {
        matcher,
        before: options.before,
        after: options.after,
        ctx_lines,
        before_to_line_start: options.before_to_line_start,
        counts_only: options.counts,
        match_empty_pattern,
        search_binary: options.binary,
        search_hidden: options.hidden,
        ext_filter_mode: options.ext_filter_mode.clone(),
        whitelist_set,
        global_match_no: global_match_no.clone(),
        shared_stats: shared_stats.clone(),
        shared_match_files: shared_match_files.clone(),
        shared_skipped_logs: shared_skipped_logs.clone(),
        cancelled,
    };

    walk.visit(&mut visitor);

    let match_count = global_match_no.load(Ordering::Relaxed);
    let failed_count = shared_stats.lock().unwrap().failed;
    let (match_files_log_path, skipped_log_path) = get_log_paths();

    let mut sorted_matches: Vec<(String, usize)> = shared_match_files
        .lock()
        .unwrap()
        .iter()
        .map(|(k, v)| (k.clone(), *v))
        .collect();
    sorted_matches.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));

    if let Some(log_path) = match_files_log_path {
        if let Some(parent) = log_path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(mut f) = std::fs::File::create(&log_path) {
            for (path, cnt) in &sorted_matches {
                let _ = writeln!(f, "{}\t{}", cnt, path);
            }
        }
    }

    if options.counts {
        let mut stdout = std::io::stdout().lock();
        for (path, cnt) in &sorted_matches {
            if writeln!(stdout, "{}\t{}", cnt, path).is_err() {
                std::process::exit(0);
            }
        }
    }

    let mut skipped_logs = shared_skipped_logs.lock().unwrap();
    skipped_logs.sort();
    if let Some(skip_path) = skipped_log_path.clone() {
        if let Some(parent) = skip_path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(mut f) = std::fs::File::create(&skip_path) {
            for p in &*skipped_logs {
                let _ = writeln!(f, "skip-rg(binary): {}", p);
            }
        }
    }

    if options.verbose {
        let stats = shared_stats.lock().unwrap();
        let tot_files = stats.seen;
        let tot_scanned = stats.attempted;
        let tot_hidden = stats.hidden_skipped;
        let tot_blisted = stats.blacklisted;
        let tot_skipped = stats.skipped;
        let tot_failed = stats.failed;

        println!("\n---- scan totals ----");
        println!("files:     {}", tot_files);
        println!("scanned:   {}", tot_scanned);
        println!("hidden:    {}", tot_hidden);
        println!("blisted:   {}", tot_blisted);
        println!("skipped:   {}", tot_skipped);
        println!("failed:    {}", tot_failed);
        println!("---- end scan totals ----\n");

        println!("---- per-extension scan summary (top 100) ----");
        println!(
            "{:<7} {:>7} {:>7} {:>7} {:>7} {:>7}",
            "ext", "scanned", "hidden", "blisted", "skipped", "failed"
        );

        let mut rows: Vec<(String, &ExtStats)> = stats
            .ext_stats
            .iter()
            .map(|(k, v)| (k.clone(), v))
            .collect();
        rows.sort_by(|a, b| {
            let tot_a = a.1.attempted + a.1.hidden_skipped + a.1.blacklisted + a.1.skipped;
            let tot_b = b.1.attempted + b.1.hidden_skipped + b.1.blacklisted + b.1.skipped;
            if tot_a != tot_b {
                return tot_b.cmp(&tot_a);
            }
            if a.1.attempted != b.1.attempted {
                return b.1.attempted.cmp(&a.1.attempted);
            }
            a.0.cmp(&b.0)
        });

        let top_n = 100;
        let mut other = [0u64; 5];
        for (idx, (ext, s)) in rows.iter().enumerate() {
            if idx < top_n {
                let ext_trunc: String = ext.chars().take(7).collect();
                println!(
                    "{:<7} {:>7} {:>7} {:>7} {:>7} {:>7}",
                    ext_trunc, s.attempted, s.hidden_skipped, s.blacklisted, s.skipped, s.failed
                );
            } else {
                other[0] += s.attempted;
                other[1] += s.hidden_skipped;
                other[2] += s.blacklisted;
                other[3] += s.skipped;
                other[4] += s.failed;
            }
        }

        if rows.len() > top_n {
            println!(
                "{:<7} {:>7} {:>7} {:>7} {:>7} {:>7}",
                "other", other[0], other[1], other[2], other[3], other[4]
            );
        }
        println!("---- end per-extension scan summary ----\n");

        if !skipped_logs.is_empty() {
            if let Some(ref path) = skipped_log_path {
                eprintln!("[g] note: some files were skipped; see: {}", path.display());
            }
        }
    }

    if failed_count > 0 {
        eprintln!(
            "[g] search completed with {} unreadable or failed file(s)",
            failed_count
        );
        std::process::exit(2);
    }

    if match_count > 0 {
        std::process::exit(0);
    } else {
        std::process::exit(1);
    }
}

fn search_stdin(
    matcher: &regex::Regex,
    before: usize,
    after: usize,
    ctx_lines: usize,
    before_to_line_start: bool,
    counts_only: bool,
    match_empty_pattern: bool,
) -> usize {
    let mut bytes = Vec::new();
    if std::io::stdin().read_to_end(&mut bytes).is_err() {
        return 0;
    }

    let content = String::from_utf8_lossy(&bytes);
    let all_lines: Vec<&str> = content.lines().collect();

    let mut file_matches = Vec::new();
    let mut match_count = 0;
    for (idx, line) in all_lines.iter().enumerate() {
        let line_no = idx + 1;
        if match_empty_pattern {
            match_count += 1;
            if !counts_only {
                file_matches.push(FileMatch {
                    line_no,
                    start_b: 0,
                    end_b: 0,
                });
            }
            continue;
        }
        for mat in matcher.find_iter(line) {
            let start_b = mat.start();
            let end_b = mat.end();
            if start_b != end_b {
                match_count += 1;
                if !counts_only {
                    file_matches.push(FileMatch {
                        line_no,
                        start_b,
                        end_b,
                    });
                }
            }
        }
    }

    if match_count > 0 {
        if !counts_only {
            let path_str = "stdin://pipe";
            let colored = std::io::stdout().is_terminal() && std::env::var_os("NO_COLOR").is_none();
            let mut stdout = std::io::stdout().lock();
            for (match_idx, m) in file_matches.iter().enumerate() {
                let match_no = match_idx + 1;
                let snippet = format_snippet_direct(SnippetRequest {
                    all_lines: &all_lines,
                    line_no: m.line_no,
                    start_b: m.start_b,
                    end_b: m.end_b,
                    before,
                    after,
                    ctx_lines,
                    before_to_line_start,
                    colored,
                });
                let green = if colored { GREEN } else { "" };
                let light_blue = if colored { LIGHT_BLUE } else { "" };
                let reset = if colored { RESET } else { "" };
                if writeln!(
                    stdout,
                    "{}{}{} {}{} {}:{}{}",
                    green, match_no, reset, light_blue, path_str, m.line_no, reset, snippet
                )
                .is_err()
                {
                    return match_count;
                }
            }
        } else {
            let mut stdout = std::io::stdout().lock();
            if writeln!(stdout, "{}\tstdin://pipe", match_count).is_err() {
                return match_count;
            }
        }
    }

    match_count
}

#[cfg(test)]
mod tests {
    use super::{format_snippet_direct, SnippetRequest};

    #[test]
    fn snippet_keeps_unicode_match_boundaries() {
        let lines = ["éxabc"];
        let output = format_snippet_direct(SnippetRequest {
            all_lines: &lines,
            line_no: 1,
            start_b: 2,
            end_b: 3,
            before: 0,
            after: 0,
            ctx_lines: 20,
            before_to_line_start: false,
            colored: true,
        });
        assert_eq!(output, "\x1b[31mx\x1b[0m");
    }

    #[test]
    fn snippet_collects_only_requested_context_across_lines() {
        let lines = ["abc", "def"];
        let output = format_snippet_direct(SnippetRequest {
            all_lines: &lines,
            line_no: 2,
            start_b: 1,
            end_b: 2,
            before: 4,
            after: 2,
            ctx_lines: 20,
            before_to_line_start: false,
            colored: true,
        });
        assert_eq!(output, "bc d\x1b[31me\x1b[0mf");
    }

    #[test]
    fn snippet_handles_saturating_line_context() {
        let lines = ["abc"];
        let output = format_snippet_direct(SnippetRequest {
            all_lines: &lines,
            line_no: 1,
            start_b: 1,
            end_b: 2,
            before: 0,
            after: 0,
            ctx_lines: usize::MAX,
            before_to_line_start: false,
            colored: false,
        });
        assert_eq!(output, "b");
    }
}
