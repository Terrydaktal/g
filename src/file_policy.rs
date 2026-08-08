use std::collections::HashSet;
use std::path::{Path, PathBuf};

// Static whitelisted extensions used by both search and audit modes.
pub const FILTER_EXTS: &[&str] = &[
    "txt",
    "md",
    "rst",
    "log",
    "csv",
    "tsv",
    "json",
    "jsonl",
    "yaml",
    "yml",
    "toml",
    "ini",
    "conf",
    "cfg",
    "xml",
    "html",
    "htm",
    "css",
    "py",
    "sh",
    "bash",
    "zsh",
    "fish",
    "c",
    "h",
    "cpp",
    "hpp",
    "cc",
    "cxx",
    "java",
    "kt",
    "go",
    "rs",
    "js",
    "mjs",
    "cjs",
    "ts",
    "tsx",
    "jsx",
    "php",
    "rb",
    "pl",
    "pdf",
    "docx",
    "doc",
    "xlsx",
    "xls",
    "pptx",
    "ppt",
    "sqlite",
    "sqlite3",
    "db",
    "db3",
    "(none)",
    "(dotfile)",
    "cmake",
    "mk",
    "mak",
    "properties",
    "lock",
    "cs",
    "ps1",
    "sql",
    "proto",
    "asm",
    "awk",
    "sed",
    "reg",
    "inc",
    "inl",
    "hxx",
    "cuh",
    "cu",
    "svg",
    "xsd",
    "xsl",
    "resx",
    "manifest",
    "sln",
    "csproj",
    "spec",
    "src",
    "ver",
    "po",
    "config",
    "pom",
    "vcproj",
    "vcxproj",
    "targets",
    "diff",
    "patch",
    "tpl",
    "tmpl",
    "template",
    "jinja",
    "plist",
    "xhtml",
    "dtd",
    "wsdl",
    "lua",
    "swift",
    "glsl",
    "hlsl",
    "wgsl",
    "shader",
    "ninja",
    "make",
    "map",
    "lst",
];

/// Return the extension used by the audit/search tables.
pub fn ext_of(path: &Path) -> String {
    let filename = match path.file_name() {
        Some(name) => name.to_string_lossy(),
        None => return "(none)".to_string(),
    };
    if filename.starts_with('.') && !filename[1..].contains('.') {
        return "(dotfile)".to_string();
    }
    match filename.rfind('.') {
        None => "(none)".to_string(),
        Some(idx) => {
            if idx == 0 {
                "(none)".to_string()
            } else {
                let ext = &filename[idx + 1..];
                if ext.is_empty() {
                    "(none)".to_string()
                } else {
                    ext.to_lowercase()
                }
            }
        }
    }
}

/// A path is hidden when any path component starts with a dot.
pub fn is_hidden_path(path: &Path) -> bool {
    for component in path.components() {
        if let Some(s) = component.as_os_str().to_str() {
            if s.starts_with('.') && s != "." && s != ".." {
                return true;
            }
        }
    }
    false
}

pub fn bucket_of(ext: &str) -> &'static str {
    match ext {
        "pdf" | "docx" | "sqlite" | "sqlite3" | "db" | "db3" => "rich",
        "xlsx" | "xls" => "xlsx",
        "pptx" | "ppt" => "pptx",
        "doc" => "doc",
        _ => "text",
    }
}

pub fn wl_yes(ext: &str, whitelist_set: &HashSet<String>) -> &'static str {
    if whitelist_set.contains(ext) {
        "yes"
    } else {
        ""
    }
}

/// Validate search roots and remove duplicate or nested paths.
pub fn resolve_roots(paths: &[String]) -> Result<Vec<String>, String> {
    if paths.is_empty() {
        return Ok(vec![".".to_string()]);
    }

    let mut candidates: Vec<(String, PathBuf)> = Vec::with_capacity(paths.len());
    for path in paths {
        let input = Path::new(path);
        if !input.exists() {
            return Err(format!("path does not exist: {}", path));
        }
        let canonical = input
            .canonicalize()
            .map_err(|error| format!("cannot resolve path '{}': {}", path, error))?;
        candidates.push((path.clone(), canonical));
    }

    let mut roots = Vec::with_capacity(candidates.len());
    for (index, (display, canonical)) in candidates.iter().enumerate() {
        let covered = candidates
            .iter()
            .enumerate()
            .any(|(other_index, (_, other))| {
                index != other_index && canonical != other && canonical.starts_with(other)
            });
        if !covered && !roots.iter().any(|(_, existing)| existing == canonical) {
            roots.push((display.clone(), canonical.clone()));
        }
    }

    Ok(roots.into_iter().map(|(display, _)| display).collect())
}

#[cfg(test)]
mod tests {
    use super::{ext_of, is_hidden_path, resolve_roots};
    use std::path::Path;

    #[test]
    fn extension_rules_match_cli_tables() {
        assert_eq!(ext_of(Path::new("src/main.rs")), "rs");
        assert_eq!(ext_of(Path::new("README")), "(none)");
        assert_eq!(ext_of(Path::new(".env")), "(dotfile)");
        assert_eq!(ext_of(Path::new("archive.")), "(none)");
        assert_eq!(ext_of(Path::new("backup.TXT")), "txt");
    }

    #[test]
    fn hidden_detection_checks_all_components() {
        assert!(is_hidden_path(Path::new("project/.git/config")));
        assert!(is_hidden_path(Path::new(".config/settings.json")));
        assert!(!is_hidden_path(Path::new("project/src/main.rs")));
    }

    #[test]
    fn root_resolution_rejects_missing_paths_and_removes_nested_roots() {
        let roots = resolve_roots(&[
            "src/search.rs".to_string(),
            "src".to_string(),
            "src".to_string(),
        ])
        .expect("test roots should resolve");
        assert_eq!(roots, vec!["src".to_string()]);

        let error = resolve_roots(&["/tmp/g-review-path-that-does-not-exist".to_string()])
            .expect_err("missing roots must be rejected");
        assert!(error.contains("does not exist"));
    }
}
