use crate::cli::Options;
use crate::file_policy::{bucket_of, ext_of, is_hidden_path, resolve_roots, wl_yes, FILTER_EXTS};
use ignore::{DirEntry, ParallelVisitor, ParallelVisitorBuilder, WalkBuilder, WalkState};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

#[derive(Default)]
struct ThreadLocalAuditData {
    non_hidden: HashMap<String, u64>,
    hidden: HashMap<String, u64>,
    bytes_non_hidden: HashMap<String, u64>,
    bytes_hidden: HashMap<String, u64>,

    wl_non: u64,
    wl_hid: u64,
    bl_non: u64,
    bl_hid: u64,
    errors: u64,
}

struct AuditVisitor {
    local_data: ThreadLocalAuditData,
    shared_data: Arc<Mutex<ThreadLocalAuditData>>,
    sizes: bool,
    whitelist_mode: bool,
    blacklist_mode: bool,
    whitelist_set: Arc<HashSet<String>>,
}

impl ParallelVisitor for AuditVisitor {
    fn visit(&mut self, entry: Result<DirEntry, ignore::Error>) -> WalkState {
        let entry = match entry {
            Ok(e) => e,
            Err(_) => {
                self.local_data.errors += 1;
                return WalkState::Continue;
            }
        };

        if !entry.file_type().map(|ft| ft.is_file()).unwrap_or(false) {
            return WalkState::Continue;
        }

        let path = entry.path();
        let ext = ext_of(path);
        let hidden = is_hidden_path(path);
        let is_wl = self.whitelist_set.contains(&ext);

        if hidden {
            if is_wl {
                self.local_data.wl_hid += 1;
            } else {
                self.local_data.bl_hid += 1;
            }
        } else if is_wl {
            self.local_data.wl_non += 1;
        } else {
            self.local_data.bl_non += 1;
        }

        let allowed = match (self.whitelist_mode, self.blacklist_mode) {
            (true, _) => is_wl,
            (_, true) => !is_wl,
            _ => true,
        };

        if allowed {
            if hidden {
                *self.local_data.hidden.entry(ext.clone()).or_insert(0) += 1;
            } else {
                *self.local_data.non_hidden.entry(ext.clone()).or_insert(0) += 1;
            }

            if self.sizes {
                let size = match entry.metadata() {
                    Ok(metadata) => metadata.len(),
                    Err(_) => {
                        self.local_data.errors += 1;
                        0
                    }
                };
                if hidden {
                    *self.local_data.bytes_hidden.entry(ext).or_insert(0) += size;
                } else {
                    *self.local_data.bytes_non_hidden.entry(ext).or_insert(0) += size;
                }
            }
        }

        WalkState::Continue
    }
}

impl Drop for AuditVisitor {
    fn drop(&mut self) {
        if let Ok(mut shared) = self.shared_data.lock() {
            for (k, v) in self.local_data.non_hidden.drain() {
                *shared.non_hidden.entry(k).or_insert(0) += v;
            }
            for (k, v) in self.local_data.hidden.drain() {
                *shared.hidden.entry(k).or_insert(0) += v;
            }
            for (k, v) in self.local_data.bytes_non_hidden.drain() {
                *shared.bytes_non_hidden.entry(k).or_insert(0) += v;
            }
            for (k, v) in self.local_data.bytes_hidden.drain() {
                *shared.bytes_hidden.entry(k).or_insert(0) += v;
            }
            shared.wl_non += self.local_data.wl_non;
            shared.wl_hid += self.local_data.wl_hid;
            shared.bl_non += self.local_data.bl_non;
            shared.bl_hid += self.local_data.bl_hid;
            shared.errors += self.local_data.errors;
        }
    }
}

struct AuditVisitorBuilder {
    shared_data: Arc<Mutex<ThreadLocalAuditData>>,
    sizes: bool,
    whitelist_mode: bool,
    blacklist_mode: bool,
    whitelist_set: Arc<HashSet<String>>,
}

impl<'s> ParallelVisitorBuilder<'s> for AuditVisitorBuilder {
    fn build(&mut self) -> Box<dyn ParallelVisitor> {
        Box::new(AuditVisitor {
            local_data: ThreadLocalAuditData::default(),
            shared_data: self.shared_data.clone(),
            sizes: self.sizes,
            whitelist_mode: self.whitelist_mode,
            blacklist_mode: self.blacklist_mode,
            whitelist_set: self.whitelist_set.clone(),
        })
    }
}

pub fn run(options: &Options) -> Result<(), Box<dyn std::error::Error>> {
    let shared_data = Arc::new(Mutex::new(ThreadLocalAuditData::default()));

    let valid_paths = match resolve_roots(&options.paths) {
        Ok(paths) => paths,
        Err(error) => {
            eprintln!("Error: {}", error);
            std::process::exit(2);
        }
    };

    let mut builder = WalkBuilder::new(&valid_paths[0]);
    for path in valid_paths.iter().skip(1) {
        builder.add(path);
    }

    // Audit mode intentionally traverses hidden entries so they can be counted.
    builder.hidden(false);
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

    let whitelist_set: Arc<HashSet<String>> =
        Arc::new(FILTER_EXTS.iter().map(|s| s.to_string()).collect());
    let walk = builder.build_parallel();
    let mut visitor = AuditVisitorBuilder {
        shared_data: shared_data.clone(),
        sizes: options.sizes,
        whitelist_mode: options.ext_filter_mode == "whitelist",
        blacklist_mode: options.ext_filter_mode == "blacklist",
        whitelist_set: whitelist_set.clone(),
    };
    walk.visit(&mut visitor);

    let data = shared_data.lock().unwrap();
    let wl_non = data.wl_non;
    let wl_hid = data.wl_hid;
    let bl_non = data.bl_non;
    let bl_hid = data.bl_hid;
    let errors = data.errors;
    let total = wl_non + wl_hid + bl_non + bl_hid;

    println!("---- audit ----");
    println!("whitelist_non_hidden: {}", wl_non);
    println!("whitelist_hidden:     {}", wl_hid);
    println!("blacklist_non_hidden: {}", bl_non);
    println!("blacklist_hidden:     {}", bl_hid);
    println!("total:               {}\n", total);

    if errors > 0 {
        eprintln!(
            "[g] audit completed with {} unreadable or failed file(s)",
            errors
        );
    }

    if options.sizes {
        println!(
            "{:<10} {:<5} {:<6} {:>12} {:>12} {:>12} {:>14}",
            "ext", "wlist", "bucket", "non_hidden", "hidden", "total", "bytes_total"
        );
    } else {
        println!(
            "{:<10} {:<5} {:<6} {:>12} {:>12} {:>12}",
            "ext", "wlist", "bucket", "non_hidden", "hidden", "total"
        );
    }

    let mut seen_exts = HashSet::new();
    for key in data.non_hidden.keys() {
        seen_exts.insert(key.clone());
    }
    for key in data.hidden.keys() {
        seen_exts.insert(key.clone());
    }
    let mut keys: Vec<String> = seen_exts.into_iter().collect();

    let non_hidden = &data.non_hidden;
    let hidden = &data.hidden;
    let bytes_non_hidden = &data.bytes_non_hidden;
    let bytes_hidden = &data.bytes_hidden;

    let get_non_hidden = |ext: &str| -> u64 { *non_hidden.get(ext).unwrap_or(&0) };
    let get_hidden = |ext: &str| -> u64 { *hidden.get(ext).unwrap_or(&0) };
    let get_bytes_non_hidden = |ext: &str| -> u64 { *bytes_non_hidden.get(ext).unwrap_or(&0) };
    let get_bytes_hidden = |ext: &str| -> u64 { *bytes_hidden.get(ext).unwrap_or(&0) };
    let get_bytes_total = |ext: &str| -> u64 { get_bytes_non_hidden(ext) + get_bytes_hidden(ext) };

    keys.sort_by(|a, b| {
        if options.sizes {
            let b1 = get_bytes_total(a);
            let b2 = get_bytes_total(b);
            if b1 != b2 {
                return b2.cmp(&b1);
            }
        }
        let t1 = get_non_hidden(a) + get_hidden(a);
        let t2 = get_non_hidden(b) + get_hidden(b);
        if t1 != t2 {
            return t2.cmp(&t1);
        }
        let n1 = get_non_hidden(a);
        let n2 = get_non_hidden(b);
        if n1 != n2 {
            return n2.cmp(&n1);
        }
        let h1 = get_hidden(a);
        let h2 = get_hidden(b);
        if h1 != h2 {
            return h2.cmp(&h1);
        }
        a.cmp(b)
    });

    let top_n = 1000;
    let mut other_non = 0;
    let mut other_hid = 0;
    let mut other_b_non = 0;
    let mut other_b_hid = 0;

    for (idx, ext) in keys.iter().enumerate() {
        let non_hidden_count = get_non_hidden(ext);
        let hidden_count = get_hidden(ext);
        let total_count = non_hidden_count + hidden_count;
        let whitelist = wl_yes(ext, &whitelist_set);
        let bucket = bucket_of(ext);

        if idx < top_n {
            if options.sizes {
                println!(
                    "{:<10} {:<5} {:<6} {:>12} {:>12} {:>12} {:>14}",
                    ext,
                    whitelist,
                    bucket,
                    non_hidden_count,
                    hidden_count,
                    total_count,
                    get_bytes_total(ext)
                );
            } else {
                println!(
                    "{:<10} {:<5} {:<6} {:>12} {:>12} {:>12}",
                    ext, whitelist, bucket, non_hidden_count, hidden_count, total_count
                );
            }
        } else {
            other_non += non_hidden_count;
            other_hid += hidden_count;
            if options.sizes {
                other_b_non += get_bytes_non_hidden(ext);
                other_b_hid += get_bytes_hidden(ext);
            }
        }
    }

    if keys.len() > top_n {
        if options.sizes {
            println!(
                "{:<10} {:<5} {:<6} {:>12} {:>12} {:>12} {:>14}",
                "other",
                "",
                "",
                other_non,
                other_hid,
                other_non + other_hid,
                other_b_non + other_b_hid
            );
        } else {
            println!(
                "{:<10} {:<5} {:<6} {:>12} {:>12} {:>12}",
                "other",
                "",
                "",
                other_non,
                other_hid,
                other_non + other_hid
            );
        }
        println!("... and {} more", keys.len() - top_n);
    } else {
        println!("---- end audit ----");
    }

    if errors > 0 {
        std::process::exit(2);
    }
    std::process::exit(0);
}
