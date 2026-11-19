//! Usagebar for Windows and Linux: a tray icon showing one provider's usage,
//! and a flyout with every signed-in provider.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod settings;
mod tray_art;

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use serde::Serialize;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, Rect, WebviewWindow, WindowEvent};
use usagebar_core::{Provider, ProviderUsage, Usagebar};

use settings::Settings;

/// Readings on screen refresh every two minutes, as on macOS.
const REFRESH_INTERVAL: Duration = Duration::from_secs(120);
const TRAY_ID: &str = "usagebar";
const FLYOUT: &str = "flyout";

#[derive(Clone, Debug, Serialize)]
struct ProviderState {
    provider: Provider,
    name: &'static str,
    /// The last successful reading, kept when a later refresh fails.
    usage: Option<ProviderUsage>,
    error: Option<String>,
}

#[derive(Clone, Debug, Default, Serialize)]
struct Snapshot {
    providers: Vec<ProviderState>,
    tray_provider: Option<Provider>,
    updated_at: Option<DateTime<Utc>>,
}

struct AppState {
    usagebar: Usagebar,
    snapshot: Mutex<Snapshot>,
    settings: Mutex<Settings>,
    /// Serializes refreshes so the timer and a manual refresh don't overlap.
    refreshing: tokio::sync::Mutex<()>,
    /// When the flyout last hid, so the tray click that hid it doesn't reopen it.
    flyout_hidden_at: Mutex<Option<Instant>>,
}

type Shared = Arc<AppState>;

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            get_snapshot,
            refresh_now,
            set_tray_provider,
            fit_flyout,
            quit
        ])
        .setup(|app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            let state: Shared = Arc::new(AppState {
                usagebar: Usagebar::new(),
                snapshot: Mutex::new(Snapshot::default()),
                settings: Mutex::new(Settings::load(app.handle())),
                refreshing: tokio::sync::Mutex::new(()),
                flyout_hidden_at: Mutex::new(None),
            });
            app.manage(state.clone());

            build_tray(app.handle())?;
            watch_flyout_focus(app.handle());

            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                loop {
                    refresh(&handle).await;
                    tokio::time::sleep(REFRESH_INTERVAL).await;
                }
            });
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("Usagebar failed to start");
}

// MARK: - Refresh

async fn refresh(app: &AppHandle) {
    let state = app.state::<Shared>().inner().clone();
    let _guard = state.refreshing.lock().await;

    let fetch = |provider: Provider| {
        let state = state.clone();
        async move {
            if !state.usagebar.has_credentials(provider) {
                return None;
            }
            Some((provider, state.usagebar.fetch(provider).await))
        }
    };
    let (claude, codex, cursor) = tokio::join!(
        fetch(Provider::Claude),
        fetch(Provider::Codex),
        fetch(Provider::Cursor)
    );

    let snapshot = {
        let mut snapshot = state.snapshot.lock().unwrap();
        let previous = std::mem::take(&mut snapshot.providers);
        for (provider, result) in [claude, codex, cursor].into_iter().flatten() {
            let last = previous
                .iter()
                .find(|p| p.provider == provider)
                .and_then(|p| p.usage.clone());
            snapshot.providers.push(match result {
                Ok(usage) => ProviderState {
                    provider,
                    name: provider.name(),
                    usage: Some(usage),
                    error: None,
                },
                Err(error) => ProviderState {
                    provider,
                    name: provider.name(),
                    usage: last,
                    error: Some(error.to_string()),
                },
            });
        }
        snapshot.tray_provider = tray_provider(
            &snapshot.providers,
            state.settings.lock().unwrap().tray_provider,
        );
        snapshot.updated_at = Some(Utc::now());
        snapshot.clone()
    };

    update_tray(app, &snapshot);
    let _ = app.emit("snapshot", &snapshot);
}

/// The user's pick when it is signed in, otherwise the first provider with a reading.
fn tray_provider(providers: &[ProviderState], preferred: Option<Provider>) -> Option<Provider> {
    preferred
        .filter(|p| providers.iter().any(|s| s.provider == *p))
        .or_else(|| {
            providers
                .iter()
                .find(|s| s.usage.is_some())
                .map(|s| s.provider)
        })
        .or_else(|| providers.first().map(|s| s.provider))
}

// MARK: - Tray

fn build_tray(app: &AppHandle) -> tauri::Result<TrayIcon> {
    let open = MenuItem::with_id(app, "open", "Open Usagebar", true, None::<&str>)?;
    let refresh_item = MenuItem::with_id(app, "refresh", "Refresh", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Usagebar", true, None::<&str>)?;
    let menu = Menu::with_items(
        app,
        &[
            &open,
            &refresh_item,
            &PredefinedMenuItem::separator(app)?,
            &quit,
        ],
    )?;

    let (pixels, size) = tray_art::render(None, None, &tray_theme());
    TrayIconBuilder::with_id(TRAY_ID)
        .icon(tauri::image::Image::new_owned(pixels, size, size))
        .icon_as_template(cfg!(target_os = "macos"))
        .tooltip("Usagebar")
        .menu(&menu)
        // Left click opens the flyout; the menu is for right click. Linux
        // trays always open the menu, which is why it has "Open Usagebar".
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "open" => show_flyout(app, None),
            "refresh" => {
                let app = app.clone();
                tauri::async_runtime::spawn(async move { refresh(&app).await });
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                rect,
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                toggle_flyout(tray.app_handle(), rect);
            }
        })
        .build(app)
}

fn update_tray(app: &AppHandle, snapshot: &Snapshot) {
    let Some(tray) = app.tray_by_id(TRAY_ID) else {
        return;
    };
    let (pixels, size) =
        tray_art::render(snapshot.tray_provider, headline(snapshot), &tray_theme());
    let _ = tray.set_icon(Some(tauri::image::Image::new_owned(pixels, size, size)));
    let _ = tray.set_icon_as_template(cfg!(target_os = "macos"));
    let _ = tray.set_tooltip(Some(tooltip(snapshot)));
}

/// The number on the tray ring: the shown provider's first window, so weekly
/// for a Claude account without a 5h window.
fn headline(snapshot: &Snapshot) -> Option<u8> {
    let shown = snapshot
        .tray_provider
        .and_then(|p| snapshot.providers.iter().find(|s| s.provider == p));
    shown
        .and_then(|s| s.usage.as_ref())
        .and_then(|u| u.windows.first())
        .map(|w| w.used_percent)
}

/// "Claude 5h 11% · 7d 46%", one line per provider.
fn tooltip(snapshot: &Snapshot) -> String {
    if snapshot.providers.is_empty() {
        return "Usagebar: sign in to Claude Code, Codex, or Cursor".into();
    }
    snapshot
        .providers
        .iter()
        .map(|state| match &state.usage {
            Some(usage) => {
                let windows: Vec<String> = usage
                    .windows
                    .iter()
                    .map(|w| format!("{} {}%", w.label, w.used_percent))
                    .collect();
                format!("{} {}", state.name, windows.join(" · "))
            }
            None => format!("{}: {}", state.name, state.error.as_deref().unwrap_or("--")),
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn tray_theme() -> tray_art::Theme {
    if cfg!(target_os = "macos") {
        return tray_art::Theme {
            foreground: "#000000",
            template: true,
        };
    }
    let light = system_uses_light_taskbar();
    tray_art::Theme {
        foreground: if light { "#1B1B1B" } else { "#FFFFFF" },
        template: false,
    }
}

/// Windows' taskbar follows "Choose your default Windows mode", not the app mode.
#[cfg(windows)]
fn system_uses_light_taskbar() -> bool {
    winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER)
        .open_subkey(r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")
        .and_then(|key| key.get_value::<u32, _>("SystemUsesLightTheme"))
        .map(|value| value == 1)
        .unwrap_or(false)
}

/// Linux panels are dark on most desktops.
#[cfg(not(windows))]
fn system_uses_light_taskbar() -> bool {
    false
}

// MARK: - Flyout

fn flyout(app: &AppHandle) -> Option<WebviewWindow> {
    app.get_webview_window(FLYOUT)
}

fn toggle_flyout(app: &AppHandle, anchor: Rect) {
    let Some(window) = flyout(app) else { return };
    if window.is_visible().unwrap_or(false) {
        let _ = window.hide();
        return;
    }
    // A click on the tray icon first takes focus from the flyout, which hides
    // it; don't reopen it on the same click.
    let just_hidden = app
        .state::<Shared>()
        .flyout_hidden_at
        .lock()
        .unwrap()
        .is_some_and(|at| at.elapsed() < Duration::from_millis(300));
    if !just_hidden {
        show_flyout(app, Some(anchor));
    }
}

fn show_flyout(app: &AppHandle, anchor: Option<Rect>) {
    let Some(window) = flyout(app) else { return };
    place_flyout(app, &window, anchor);
    let _ = window.show();
    let _ = window.set_focus();
    let _ = app.emit(
        "snapshot",
        &app.state::<Shared>().snapshot.lock().unwrap().clone(),
    );
}

/// Puts the flyout next to the tray icon, on the side away from the taskbar,
/// inside the monitor's work area. Without an anchor (Linux), top right.
fn place_flyout(app: &AppHandle, window: &WebviewWindow, anchor: Option<Rect>) {
    let Ok(size) = window.outer_size() else {
        return;
    };
    let (width, height) = (f64::from(size.width), f64::from(size.height));
    const GAP: f64 = 12.0;

    let (point, icon_height) = match anchor {
        Some(rect) => {
            let scale = window.scale_factor().unwrap_or(1.0);
            let position = rect.position.to_physical::<f64>(scale);
            let icon = rect.size.to_physical::<f64>(scale);
            ((position.x + icon.width / 2.0, position.y), icon.height)
        }
        None => match window.primary_monitor() {
            Ok(Some(monitor)) => (
                (
                    f64::from(monitor.position().x) + f64::from(monitor.size().width),
                    f64::from(monitor.position().y),
                ),
                0.0,
            ),
            _ => return,
        },
    };
    let monitor = app
        .monitor_from_point(point.0, point.1)
        .ok()
        .flatten()
        .or_else(|| window.current_monitor().ok().flatten())
        .or_else(|| window.primary_monitor().ok().flatten());
    let Some(monitor) = monitor else { return };
    let area = monitor.work_area();
    let (left, top) = (f64::from(area.position.x), f64::from(area.position.y));
    let (right, bottom) = (
        left + f64::from(area.size.width),
        top + f64::from(area.size.height),
    );

    let x = (point.0 - width / 2.0).clamp(left + GAP, right - width - GAP);
    // Icon in the lower half: taskbar at the bottom, open upward.
    let y = if point.1 > top + (bottom - top) / 2.0 {
        point.1 - height - GAP
    } else {
        point.1 + icon_height + GAP
    }
    .clamp(top + GAP, bottom - height - GAP);
    let _ = window.set_position(PhysicalPosition::new(x.round() as i32, y.round() as i32));
}

fn watch_flyout_focus(app: &AppHandle) {
    let Some(window) = flyout(app) else { return };
    let handle = app.clone();
    let hider = window.clone();
    window.on_window_event(move |event| {
        if let WindowEvent::Focused(false) = event {
            let _ = hider.hide();
            *handle.state::<Shared>().flyout_hidden_at.lock().unwrap() = Some(Instant::now());
        }
    });
}

// MARK: - Commands

#[tauri::command]
fn get_snapshot(state: tauri::State<'_, Shared>) -> Snapshot {
    state.snapshot.lock().unwrap().clone()
}

#[tauri::command]
async fn refresh_now(app: AppHandle) -> Snapshot {
    refresh(&app).await;
    app.state::<Shared>().snapshot.lock().unwrap().clone()
}

#[tauri::command]
fn set_tray_provider(app: AppHandle, provider: Provider) {
    let state = app.state::<Shared>().inner().clone();
    {
        let mut settings = state.settings.lock().unwrap();
        settings.tray_provider = Some(provider);
        settings.save(&app);
    }
    let snapshot = {
        let mut snapshot = state.snapshot.lock().unwrap();
        snapshot.tray_provider = tray_provider(&snapshot.providers, Some(provider));
        snapshot.clone()
    };
    update_tray(&app, &snapshot);
    let _ = app.emit("snapshot", &snapshot);
}

/// The flyout sizes itself to its content, then keeps its edge by the tray.
#[tauri::command]
fn fit_flyout(window: WebviewWindow, height: f64) {
    let Ok(old) = window.outer_size() else { return };
    let scale = window.scale_factor().unwrap_or(1.0);
    let width = f64::from(old.width) / scale;
    let _ = window.set_size(tauri::LogicalSize::new(width, height.clamp(120.0, 720.0)));
    // Keep the edge that faces the taskbar in place.
    if let (Ok(position), Ok(new)) = (window.outer_position(), window.outer_size()) {
        if let Ok(Some(monitor)) = window.current_monitor() {
            let area = monitor.work_area();
            let middle = area.position.y + area.size.height as i32 / 2;
            if position.y > middle - old.height as i32 {
                let bottom = position.y + old.height as i32;
                let _ = window.set_position(PhysicalPosition::new(
                    position.x,
                    bottom - new.height as i32,
                ));
            }
        }
    }
}

#[tauri::command]
fn quit(app: AppHandle) {
    app.exit(0);
}

#[cfg(test)]
mod tests {
    use usagebar_core::UsageWindow;

    use super::*;

    fn claude_snapshot(windows: &[(&str, u8)]) -> Snapshot {
        Snapshot {
            providers: vec![ProviderState {
                provider: Provider::Claude,
                name: Provider::Claude.name(),
                usage: Some(ProviderUsage {
                    provider: Provider::Claude,
                    detail: None,
                    windows: windows
                        .iter()
                        .map(|(label, used_percent)| UsageWindow {
                            label: (*label).into(),
                            used_percent: *used_percent,
                            resets_at: None,
                        })
                        .collect(),
                }),
                error: None,
            }],
            tray_provider: Some(Provider::Claude),
            updated_at: None,
        }
    }

    #[test]
    fn tray_leads_with_5h_when_the_account_has_it() {
        let snapshot = claude_snapshot(&[("5h", 11), ("7d", 46)]);
        assert_eq!(headline(&snapshot), Some(11));
        assert_eq!(tooltip(&snapshot), "Claude 5h 11% · 7d 46%");
    }

    #[test]
    fn tray_falls_back_to_7d_without_a_5h_window() {
        let snapshot = claude_snapshot(&[("7d", 46)]);
        assert_eq!(headline(&snapshot), Some(46));
        assert_eq!(tooltip(&snapshot), "Claude 7d 46%");

        let snapshot = claude_snapshot(&[("7d", 46), ("Fable", 12)]);
        assert_eq!(headline(&snapshot), Some(46));
        assert_eq!(tooltip(&snapshot), "Claude 7d 46% · Fable 12%");
    }
}
