//! Prints each provider's normalized usage. Never prints credentials.
//!
//!     cargo run -p usagebar-core --example status

use usagebar_core::{Provider, Usagebar};

#[tokio::main]
async fn main() {
    let usagebar = Usagebar::new();
    for provider in Provider::ALL {
        if !usagebar.has_credentials(provider) {
            println!("{}: no credentials found", provider.name());
            continue;
        }
        match usagebar.fetch(provider).await {
            Ok(usage) => {
                let windows: Vec<String> = usage
                    .windows
                    .iter()
                    .map(|w| {
                        let reset = w
                            .resets_at
                            .map(|t| t.to_rfc3339())
                            .unwrap_or_else(|| "--".into());
                        format!("{} {}% (resets {reset})", w.label, w.used_percent)
                    })
                    .collect();
                println!(
                    "{} [{}]: {}",
                    provider.name(),
                    usage.detail.unwrap_or_default(),
                    windows.join(", ")
                );
            }
            Err(error) => println!("{}: {error}", provider.name()),
        }
    }
}
