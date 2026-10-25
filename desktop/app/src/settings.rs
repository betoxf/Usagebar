//! Display preferences, stored as JSON in the app's config folder
//! (`%APPDATA%\dev.usagebar.desktop` on Windows, `~/.config/dev.usagebar.desktop` on Linux).

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager};
use usagebar_core::Provider;

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    /// The provider the tray icon shows; the first signed-in one when unset.
    pub tray_provider: Option<Provider>,
}

impl Settings {
    pub fn load(app: &AppHandle) -> Self {
        path(app)
            .and_then(|path| std::fs::read(path).ok())
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, app: &AppHandle) {
        let Some(path) = path(app) else { return };
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(json) = serde_json::to_vec_pretty(self) {
            let _ = std::fs::write(path, json);
        }
    }
}

fn path(app: &AppHandle) -> Option<std::path::PathBuf> {
    app.path()
        .app_config_dir()
        .ok()
        .map(|dir| dir.join("settings.json"))
}
