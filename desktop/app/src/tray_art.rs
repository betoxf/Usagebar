//! Draws the tray icon: the provider's mark inside a ring that fills with
//! usage. Tray icons are square and tiny (16 px at 100% scaling on Windows),
//! so the ring carries the number and the tooltip spells it out.

use resvg::{tiny_skia, usvg};
use usagebar_core::Provider;

/// Rendered size in pixels. Windows downsamples it for 100% scaling and uses
/// it as is at 200%.
const SIZE: u32 = 32;

const CLAUDE: &str = include_str!("../../ui/marks/claude.svg");
const CODEX: &str = include_str!("../../ui/marks/codex.svg");
const CURSOR: &str = include_str!("../../ui/marks/cursor.svg");

/// Claude's brand orange, used for its ring; other marks are monochrome.
const CLAUDE_ORANGE: &str = "#D97757";

pub struct Theme {
    /// Color of the mark and the ring on this taskbar.
    pub foreground: &'static str,
    /// Whether the system recolors the icon itself (macOS template images),
    /// in which case brand colors are dropped.
    pub template: bool,
}

/// Returns straight RGBA pixels, `SIZE` x `SIZE`.
pub fn render(
    provider: Option<Provider>,
    used_percent: Option<u8>,
    theme: &Theme,
) -> (Vec<u8>, u32) {
    let fg = theme.foreground;
    let accent = match provider {
        Some(Provider::Claude) if !theme.template => CLAUDE_ORANGE,
        _ => fg,
    };

    let mut svg = format!(
        r#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
<circle cx="16" cy="16" r="14" fill="none" stroke="{fg}" stroke-opacity="0.28" stroke-width="3"/>"#
    );
    if let Some(percent) = used_percent.filter(|p| *p > 0) {
        svg.push_str(&ring(percent, accent));
    }
    if let Some(mark) = provider.map(mark) {
        svg.push_str(&nested(mark, fg));
    }
    svg.push_str("</svg>");

    (rasterize(&svg), SIZE)
}

fn mark(provider: Provider) -> &'static str {
    match provider {
        Provider::Claude => CLAUDE,
        Provider::Codex => CODEX,
        Provider::Cursor => CURSOR,
    }
}

/// An arc from 12 o'clock, clockwise, covering `percent` of the ring.
fn ring(percent: u8, color: &str) -> String {
    let stroke = format!(r#"fill="none" stroke="{color}" stroke-width="3" stroke-linecap="round""#);
    if percent >= 100 {
        return format!(r#"<circle cx="16" cy="16" r="14" {stroke}/>"#);
    }
    let angle = f32::from(percent) / 100.0 * std::f32::consts::TAU;
    let (x, y) = (16.0 + 14.0 * angle.sin(), 16.0 - 14.0 * angle.cos());
    let large = i32::from(percent > 50);
    format!(r#"<path d="M16 2 A14 14 0 {large} 1 {x:.3} {y:.3}" {stroke}/>"#)
}

/// Places a mark's own `<svg>` in the 14 px square at the ring's center.
fn nested(mark: &str, color: &str) -> String {
    mark.trim()
        .replacen(
            r#"xmlns="http://www.w3.org/2000/svg" "#,
            r#"x="9" y="9" width="14" height="14" "#,
            1,
        )
        .replace(r#"fill="black""#, &format!(r#"fill="{color}""#))
}

fn rasterize(svg: &str) -> Vec<u8> {
    let tree = usvg::Tree::from_str(svg, &usvg::Options::default()).expect("tray SVG is valid");
    let mut pixmap = tiny_skia::Pixmap::new(SIZE, SIZE).expect("tray size is non-zero");
    let scale = SIZE as f32 / tree.size().width();
    resvg::render(
        &tree,
        tiny_skia::Transform::from_scale(scale, scale),
        &mut pixmap.as_mut(),
    );
    // tiny-skia stores premultiplied alpha; tray APIs want straight RGBA.
    pixmap
        .pixels()
        .iter()
        .flat_map(|p| {
            let c = p.demultiply();
            [c.red(), c.green(), c.blue(), c.alpha()]
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_every_provider_and_percent() {
        let theme = Theme {
            foreground: "#FFFFFF",
            template: false,
        };
        for provider in Provider::ALL {
            for percent in [None, Some(0), Some(37), Some(51), Some(100)] {
                let (pixels, size) = render(Some(provider), percent, &theme);
                assert_eq!(pixels.len(), (size * size * 4) as usize);
                assert!(
                    pixels.chunks(4).any(|p| p[3] > 0),
                    "{provider:?} {percent:?} drew nothing"
                );
            }
        }
    }

    /// `USAGEBAR_TRAY_PREVIEW=/abs/dir cargo test -p usagebar-desktop` saves
    /// enlarged icons on dark and light taskbars for review.
    #[test]
    fn writes_previews_when_asked() {
        let Some(dir) = std::env::var_os("USAGEBAR_TRAY_PREVIEW") else {
            return;
        };
        let themes = [
            ("dark", "#FFFFFF", [32, 32, 32]),
            ("light", "#1B1B1B", [243, 243, 243]),
        ];
        for (name, foreground, background) in themes {
            let theme = Theme {
                foreground,
                template: false,
            };
            let cells: Vec<_> = [
                (Provider::Claude, 47),
                (Provider::Codex, 17),
                (Provider::Cursor, 31),
                (Provider::Claude, 100),
            ]
            .into_iter()
            .map(|(provider, percent)| render(Some(provider), Some(percent), &theme).0)
            .collect();
            let (cell, gap) = (SIZE, 8);
            let width = cells.len() as u32 * (cell + gap) + gap;
            let height = cell + 2 * gap;
            let mut sheet = tiny_skia::Pixmap::new(width, height).unwrap();
            sheet.fill(tiny_skia::Color::from_rgba8(
                background[0],
                background[1],
                background[2],
                255,
            ));
            for (i, pixels) in cells.iter().enumerate() {
                let premultiplied: Vec<u8> = pixels
                    .chunks(4)
                    .flat_map(|p| {
                        let c = tiny_skia::ColorU8::from_rgba(p[0], p[1], p[2], p[3]).premultiply();
                        [c.red(), c.green(), c.blue(), c.alpha()]
                    })
                    .collect();
                let icon = tiny_skia::Pixmap::from_vec(
                    premultiplied,
                    tiny_skia::IntSize::from_wh(cell, cell).unwrap(),
                )
                .unwrap();
                let x = (gap + i as u32 * (cell + gap)) as i32;
                sheet.draw_pixmap(
                    x,
                    gap as i32,
                    icon.as_ref(),
                    &tiny_skia::PixmapPaint::default(),
                    tiny_skia::Transform::identity(),
                    None,
                );
            }
            sheet
                .save_png(std::path::Path::new(&dir).join(format!("tray-{name}.png")))
                .unwrap();
        }
    }
}
