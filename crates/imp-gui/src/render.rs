//! Draws a `Frame` with wgpu: cell backgrounds, underlines and the cursor
//! as colored quads, then the text with glyphon (cosmic-text).
//!
//! The grid is the frame's: each span starts at the column the widths of
//! the spans before it reach, so text stays on its cells even where a
//! fallback font's glyphs are wider. Rows are shaped again only when they
//! change.

use glyphon::cosmic_text::fontdb;
use glyphon::{
    Attrs, Buffer, Cache, Family, FontSystem, Metrics, Resolution, Shaping, SwashCache, TextArea,
    TextAtlas, TextBounds, TextRenderer, Viewport, Weight,
};
use imp_core::{Color, CursorShape, Frame, Row, Style};
use unicode_width::UnicodeWidthStr;

/// Colors for spans that leave them unset (the theme usually sets them).
const DEFAULT_FG: (u8, u8, u8) = (0xab, 0xb2, 0xbf);
const DEFAULT_BG: (u8, u8, u8) = (0x28, 0x2c, 0x34);

pub struct Font {
    /// A family name, or "monospace" for the system's.
    pub family: String,
    /// Font files to load besides the system's.
    pub files: Vec<std::path::PathBuf>,
    pub size: f32,
}

/// One colored rectangle, in pixels.
#[derive(Clone, Copy, PartialEq)]
struct Quad {
    rect: [f32; 4],
    color: [f32; 4],
}

/// A row as last drawn, and what it was drawn from.
struct RowCache {
    key: (Row, Option<(u16, CursorShape)>),
    texts: Vec<(f32, Buffer)>,
    quads: Vec<Quad>,
}

pub struct Renderer {
    pub device: wgpu::Device,
    pub queue: wgpu::Queue,
    font_system: FontSystem,
    swash: SwashCache,
    viewport: Viewport,
    atlas: TextAtlas,
    text: TextRenderer,
    pipeline: wgpu::RenderPipeline,
    screen: wgpu::Buffer,
    screen_group: wgpu::BindGroup,
    quads: wgpu::Buffer,
    family: String,
    metrics: Metrics,
    /// Cell width and height in pixels.
    pub cell: (f32, f32),
    rows: Vec<Option<RowCache>>,
}

const SHADER: &str = r#"
struct Screen { size: vec4<f32> };
@group(0) @binding(0) var<uniform> screen: Screen;

struct Quad {
    @location(0) rect: vec4<f32>,
    @location(1) color: vec4<f32>,
};
struct Out {
    @builtin(position) pos: vec4<f32>,
    @location(0) color: vec4<f32>,
};

@vertex
fn vs(@builtin(vertex_index) v: u32, q: Quad) -> Out {
    var corners = array<vec2<f32>, 6>(
        vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
        vec2(0.0, 1.0), vec2(1.0, 0.0), vec2(1.0, 1.0));
    let p = q.rect.xy + corners[v] * q.rect.zw;
    var out: Out;
    out.pos = vec4(p.x / screen.size.x * 2.0 - 1.0, 1.0 - p.y / screen.size.y * 2.0, 0.0, 1.0);
    out.color = q.color;
    return out;
}

@fragment
fn fs(i: Out) -> @location(0) vec4<f32> {
    return i.color;
}
"#;

impl Renderer {
    pub fn new(
        device: wgpu::Device,
        queue: wgpu::Queue,
        format: wgpu::TextureFormat,
        font: &Font,
    ) -> Renderer {
        let mut font_system = FontSystem::new();
        for file in &font.files {
            if let Err(e) = font_system.db_mut().load_font_file(file) {
                eprintln!("imp: {}: {e}", file.display());
            }
        }
        pick_monospace_family(font_system.db_mut());
        let cache = Cache::new(&device);
        let viewport = Viewport::new(&device, &cache);
        let mut atlas = TextAtlas::new(&device, &queue, &cache, format);
        let text = TextRenderer::new(&mut atlas, &device, wgpu::MultisampleState::default(), None);

        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("quads"),
            source: wgpu::ShaderSource::Wgsl(SHADER.into()),
        });
        let screen = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("screen"),
            size: 16,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: None,
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            }],
        });
        let screen_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: screen.as_entire_binding(),
            }],
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: None,
            bind_group_layouts: &[Some(&layout)],
            ..Default::default()
        });
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("quads"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs"),
                compilation_options: Default::default(),
                buffers: &[Some(wgpu::VertexBufferLayout {
                    array_stride: 32,
                    step_mode: wgpu::VertexStepMode::Instance,
                    attributes: &wgpu::vertex_attr_array![0 => Float32x4, 1 => Float32x4],
                })],
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: Some(wgpu::BlendState::ALPHA_BLENDING),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview_mask: None,
            cache: None,
        });
        let quads = quad_buffer(&device, 1024);

        let metrics = Metrics::new(font.size, (font.size * 1.3).round());
        let mut renderer = Renderer {
            device,
            queue,
            font_system,
            swash: SwashCache::new(),
            viewport,
            atlas,
            text,
            pipeline,
            screen,
            screen_group,
            quads,
            family: font.family.clone(),
            metrics,
            cell: (0.0, metrics.line_height),
            rows: Vec::new(),
        };
        renderer.cell.0 = renderer.measure_cell();
        renderer
    }

    fn attrs(&self) -> Attrs<'_> {
        let attrs = Attrs::new();
        match self.family.as_str() {
            "monospace" => attrs.family(Family::Monospace),
            name => attrs.family(Family::Name(name)),
        }
    }

    /// The advance of "M": the cell width. Warns if "i" differs, since a
    /// proportional font can't keep text on the grid.
    fn measure_cell(&mut self) -> f32 {
        let mut advance = |text: &str| {
            let mut buffer = Buffer::new(&mut self.font_system, self.metrics);
            let attrs = self.attrs();
            buffer.set_text(text, &attrs, Shaping::Advanced, None);
            buffer.shape_until_scroll(&mut self.font_system, false);
            let w = buffer
                .layout_runs()
                .flat_map(|run| run.glyphs.iter().map(|g| g.w))
                .next();
            w.unwrap_or(self.metrics.font_size * 0.6)
        };
        let (m, i) = (advance("M"), advance("i"));
        if (m - i).abs() > 0.5 {
            eprintln!(
                "imp: font {:?} is not monospace, so text won't line up; \
                 pick one with --font or --font-file",
                self.family
            );
        }
        m.max(1.0)
    }

    /// Changes the font size; everything is laid out again.
    pub fn set_font_size(&mut self, size: f32) {
        self.metrics = Metrics::new(size, (size * 1.3).round());
        self.cell = (self.measure_cell(), self.metrics.line_height);
        self.rows.clear();
    }

    /// How many cells fit in `width` x `height` pixels.
    pub fn grid(&self, width: u32, height: u32) -> (u16, u16) {
        (
            ((width as f32 / self.cell.0) as u16).max(1),
            ((height as f32 / self.cell.1) as u16).max(1),
        )
    }

    /// Draws `frame` into `target`, a `width` x `height` texture.
    pub fn draw(&mut self, frame: &Frame, target: &wgpu::TextureView, width: u32, height: u32) {
        self.rows.resize_with(frame.rows.len(), || None);
        for (i, row) in frame.rows.iter().enumerate() {
            let cursor =
                (frame.cursor.1 as usize == i).then_some((frame.cursor.0, frame.cursor_shape));
            let fresh = match &self.rows[i] {
                Some(cache) => cache.key.0 != *row || cache.key.1 != cursor,
                None => true,
            };
            if fresh {
                self.rows[i] = Some(self.layout_row(row, cursor, i));
            }
        }

        let quads: Vec<Quad> = self
            .rows
            .iter()
            .flatten()
            .flat_map(|r| r.quads.iter().copied())
            .collect();
        if quads.len() as u64 * 32 > self.quads.size() {
            self.quads = quad_buffer(&self.device, quads.len() * 2);
        }
        let bytes: Vec<u8> = quads
            .iter()
            .flat_map(|q| q.rect.iter().chain(&q.color).flat_map(|f| f.to_ne_bytes()))
            .collect();
        self.queue.write_buffer(&self.quads, 0, &bytes);
        let size: Vec<u8> = [width as f32, height as f32, 0.0, 0.0]
            .iter()
            .flat_map(|f| f.to_ne_bytes())
            .collect();
        self.queue.write_buffer(&self.screen, 0, &size);

        self.viewport
            .update(&self.queue, Resolution { width, height });
        let areas = self.rows.iter().enumerate().flat_map(|(i, row)| {
            let top = i as f32 * self.cell.1;
            row.iter().flat_map(move |r| {
                r.texts.iter().map(move |(left, buffer)| TextArea {
                    buffer,
                    left: *left,
                    top,
                    scale: 1.0,
                    bounds: TextBounds {
                        left: 0,
                        top: 0,
                        right: width as i32,
                        bottom: height as i32,
                    },
                    default_color: glyphon::Color::rgb(DEFAULT_FG.0, DEFAULT_FG.1, DEFAULT_FG.2),
                    custom_glyphs: &[],
                })
            })
        });
        if let Err(e) = self.text.prepare(
            &self.device,
            &self.queue,
            &mut self.font_system,
            &mut self.atlas,
            &self.viewport,
            areas,
            &mut self.swash,
        ) {
            eprintln!("imp: {e}");
        }

        let mut encoder = self.device.create_command_encoder(&Default::default());
        {
            let bg = linear(DEFAULT_BG);
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: None,
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: target,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: bg[0] as f64,
                            g: bg[1] as f64,
                            b: bg[2] as f64,
                            a: 1.0,
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            if !quads.is_empty() {
                pass.set_pipeline(&self.pipeline);
                pass.set_bind_group(0, &self.screen_group, &[]);
                pass.set_vertex_buffer(0, self.quads.slice(..));
                pass.draw(0..6, 0..quads.len() as u32);
            }
            if let Err(e) = self.text.render(&self.atlas, &self.viewport, &mut pass) {
                eprintln!("imp: {e}");
            }
        }
        self.queue.submit(Some(encoder.finish()));
        self.atlas.trim();
    }

    /// Lays out screen row `y`: its quads and shaped text.
    fn layout_row(&mut self, row: &Row, cursor: Option<(u16, CursorShape)>, y: usize) -> RowCache {
        let (cw, ch) = self.cell;
        let top = y as f32 * ch;
        let mut quads = Vec::new();
        let mut texts = Vec::new();
        let mut col = 0usize;
        for (text, style) in cells_with_cursor(row, cursor) {
            let width = text.width();
            let (fg, bg) = colors(style);
            let left = col as f32 * cw;
            if bg != DEFAULT_BG || style.reverse {
                quads.push(Quad {
                    rect: [left, top, width as f32 * cw, ch],
                    color: rgba(bg),
                });
            }
            if style.underline {
                quads.push(Quad {
                    rect: [left, top + ch - 2.0, width as f32 * cw, 1.0],
                    color: rgba(fg),
                });
            }
            if !text.trim().is_empty() {
                let mut buffer = Buffer::new(&mut self.font_system, self.metrics);
                let mut attrs = self.attrs().color(glyphon::Color::rgb(fg.0, fg.1, fg.2));
                if style.bold {
                    attrs = attrs.weight(Weight::BOLD);
                }
                if style.italic {
                    attrs = attrs.style(glyphon::Style::Italic);
                }
                buffer.set_size(None, Some(ch));
                buffer.set_text(&text, &attrs, Shaping::Advanced, None);
                buffer.shape_until_scroll(&mut self.font_system, false);
                texts.push((left, buffer));
            }
            col += width;
        }
        if let Some((x, shape)) = cursor {
            let left = x as f32 * cw;
            let fg = rgba(cursor_color(row, x));
            match shape {
                CursorShape::Block => {}
                CursorShape::Bar => quads.push(Quad {
                    rect: [left, top, 2.0, ch],
                    color: fg,
                }),
                CursorShape::Underline => quads.push(Quad {
                    rect: [left, top + ch - 2.0, cw, 2.0],
                    color: fg,
                }),
            }
        }
        RowCache {
            key: (row.clone(), cursor),
            texts,
            quads,
        }
    }
}

fn quad_buffer(device: &wgpu::Device, quads: usize) -> wgpu::Buffer {
    device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("quads"),
        size: quads as u64 * 32,
        usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    })
}

/// The spans of `row`, with a block cursor's cell split out and its
/// colors swapped (the cell under a block cursor is drawn inverted).
fn cells_with_cursor(row: &Row, cursor: Option<(u16, CursorShape)>) -> Vec<(String, Style)> {
    let block = match cursor {
        Some((x, CursorShape::Block)) => Some(x as usize),
        _ => None,
    };
    let mut out = Vec::new();
    let mut col = 0;
    let mut drawn_cursor = false;
    for span in row {
        let width = span.text.width();
        match block {
            Some(x) if x >= col && x < col + width => {
                let (mut before, mut at, mut after) = (String::new(), String::new(), String::new());
                let mut c = col;
                for ch in span.text.chars() {
                    let w = unicode_width::UnicodeWidthChar::width(ch).unwrap_or(0);
                    if c + w <= x && at.is_empty() {
                        before.push(ch)
                    } else if at.is_empty() || (w == 0 && after.is_empty()) {
                        // The char under the cursor, and any marks on it.
                        at.push(ch)
                    } else {
                        after.push(ch)
                    }
                    c += w;
                }
                let inverted = Style {
                    reverse: !span.style.reverse,
                    ..span.style
                };
                for (text, style) in [(before, span.style), (at, inverted), (after, span.style)] {
                    if !text.is_empty() {
                        out.push((text, style));
                    }
                }
                drawn_cursor = true;
            }
            _ => out.push((span.text.clone(), span.style)),
        }
        col += width;
    }
    // A cursor past the end of the row's text (an empty line, end of line).
    if let Some(x) = block {
        if !drawn_cursor {
            if x > col {
                out.push((" ".repeat(x - col), Style::default()));
            }
            out.push((
                " ".into(),
                Style {
                    reverse: true,
                    ..Style::default()
                },
            ));
        }
    }
    out
}

/// The text color at column `x`, for a bar or underline cursor.
fn cursor_color(row: &Row, x: u16) -> (u8, u8, u8) {
    let mut col = 0;
    for span in row {
        col += span.text.width();
        if col > x as usize {
            return colors(span.style).0;
        }
    }
    DEFAULT_FG
}

/// The (fg, bg) a style draws with, reverse applied.
fn colors(style: Style) -> ((u8, u8, u8), (u8, u8, u8)) {
    let fg = style.fg.map_or(DEFAULT_FG, rgb);
    let bg = style.bg.map_or(DEFAULT_BG, rgb);
    if style.reverse {
        (bg, fg)
    } else {
        (fg, bg)
    }
}

/// A color as RGB: the 16 ANSI colors as One Dark draws them, then the
/// standard 256-color cube and grays.
fn rgb(c: Color) -> (u8, u8, u8) {
    const ANSI: [(u8, u8, u8); 16] = [
        (0x28, 0x2c, 0x34),
        (0xe0, 0x6c, 0x75),
        (0x98, 0xc3, 0x79),
        (0xe5, 0xc0, 0x7b),
        (0x61, 0xaf, 0xef),
        (0xc6, 0x78, 0xdd),
        (0x56, 0xb6, 0xc2),
        (0xab, 0xb2, 0xbf),
        (0x5c, 0x63, 0x70),
        (0xe0, 0x6c, 0x75),
        (0x98, 0xc3, 0x79),
        (0xe5, 0xc0, 0x7b),
        (0x61, 0xaf, 0xef),
        (0xc6, 0x78, 0xdd),
        (0x56, 0xb6, 0xc2),
        (0xdc, 0xdf, 0xe4),
    ];
    match c {
        Color::Rgb(r, g, b) => (r, g, b),
        Color::Indexed(n) if n < 16 => ANSI[n as usize],
        Color::Indexed(n) if n < 232 => {
            let n = n - 16;
            let level = |v: u8| if v == 0 { 0 } else { 55 + v * 40 };
            (level(n / 36), level((n / 6) % 6), level(n % 6))
        }
        Color::Indexed(n) => {
            let v = 8 + (n - 232) * 10;
            (v, v, v)
        }
    }
}

/// sRGB to the linear values an sRGB target expects from a shader.
fn linear((r, g, b): (u8, u8, u8)) -> [f32; 3] {
    let f = |c: u8| {
        let c = c as f32 / 255.0;
        if c <= 0.04045 {
            c / 12.92
        } else {
            ((c + 0.055) / 1.055).powf(2.4)
        }
    };
    [f(r), f(g), f(b)]
}

fn rgba(c: (u8, u8, u8)) -> [f32; 4] {
    let [r, g, b] = linear(c);
    [r, g, b, 1.0]
}

/// fontdb assumes the monospace family by name (Noto Sans Mono on Linux).
/// When that isn't installed, cosmic-text falls back to the first
/// monospaced face it meets, which may well be an italic one. So point
/// "monospace" at an installed family: fontconfig's choice, else the first
/// monospaced family, by name, with a regular upright face.
fn pick_monospace_family(db: &mut fontdb::Database) {
    let installed = |db: &fontdb::Database, name: &str| {
        db.faces()
            .any(|f| f.families.iter().any(|(n, _)| n == name))
    };
    if installed(db, db.family_name(&fontdb::Family::Monospace)) {
        return;
    }
    let choice = fontconfig_monospace()
        .filter(|name| installed(db, name))
        .or_else(|| {
            db.faces()
                .filter(|f| {
                    f.monospaced
                        && f.style == fontdb::Style::Normal
                        && f.weight == fontdb::Weight::NORMAL
                })
                .filter_map(|f| f.families.first().map(|(n, _)| n.clone()))
                .min()
        });
    if let Some(name) = choice {
        db.set_monospace_family(name);
    }
}

/// The family fontconfig gives for "monospace", if fc-match is there.
fn fontconfig_monospace() -> Option<String> {
    let out = std::process::Command::new("fc-match")
        .args(["-f", "%{family[0]}", "monospace"])
        .output()
        .ok()?;
    let name = String::from_utf8(out.stdout).ok()?;
    (out.status.success() && !name.trim().is_empty()).then(|| name.trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use imp_core::Span;

    #[test]
    fn a_block_cursor_inverts_its_cell() {
        let row = vec![Span::new("héllo", Style::default())];
        let cells = cells_with_cursor(&row, Some((1, CursorShape::Block)));
        let texts: Vec<&str> = cells.iter().map(|(t, _)| t.as_str()).collect();
        assert_eq!(texts, ["h", "é", "llo"]);
        assert!(cells[1].1.reverse && !cells[0].1.reverse);
        // Past the end of the text, a cell is added for it.
        let cells = cells_with_cursor(&row, Some((7, CursorShape::Block)));
        assert_eq!(cells.len(), 3);
        assert_eq!(cells[1].0, "  ");
        assert!(cells[2].1.reverse);
        // Other shapes leave the text alone.
        assert_eq!(
            cells_with_cursor(&row, Some((1, CursorShape::Bar))).len(),
            1
        );
    }

    #[test]
    fn wide_chars_take_their_cells() {
        let row = vec![Span::new("日本x", Style::default())];
        let cells = cells_with_cursor(&row, Some((2, CursorShape::Block)));
        let texts: Vec<&str> = cells.iter().map(|(t, _)| t.as_str()).collect();
        assert_eq!(texts, ["日", "本", "x"]);
    }

    #[test]
    fn colors_resolve() {
        assert_eq!(rgb(Color::Indexed(16)), (0, 0, 0));
        assert_eq!(rgb(Color::Indexed(231)), (255, 255, 255));
        assert_eq!(rgb(Color::Indexed(255)), (238, 238, 238));
        let s = Style {
            fg: Some(Color::Rgb(1, 2, 3)),
            reverse: true,
            ..Style::default()
        };
        assert_eq!(colors(s), (DEFAULT_BG, (1, 2, 3)));
    }

    #[test]
    fn monospace_is_an_installed_upright_family() {
        let mut db = fontdb::Database::new();
        db.load_system_fonts();
        let Some(upright) = db
            .faces()
            .find(|f| f.monospaced && f.style == fontdb::Style::Normal)
            .map(|f| f.families[0].0.clone())
        else {
            return; // no monospaced fonts on this machine
        };
        db.set_monospace_family("No Such Font");
        pick_monospace_family(&mut db);
        let name = db.family_name(&fontdb::Family::Monospace).to_string();
        assert_ne!(name, "No Such Font");
        let id = db
            .query(&fontdb::Query {
                families: &[fontdb::Family::Name(&name)],
                ..Default::default()
            })
            .unwrap_or_else(|| panic!("{name} (vs {upright})"));
        assert_eq!(db.face(id).unwrap().style, fontdb::Style::Normal);
    }
}
