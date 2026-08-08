mod audit;
mod cli;
mod file_policy;
mod search;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let options = cli::parse_args();
    if options.audit {
        audit::run(&options)
    } else {
        search::run(&options)
    }
}
