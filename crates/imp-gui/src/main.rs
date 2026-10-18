//! `imp-gui`: a GPU client for imp (Phase 5 prototype).
//!
//! Like the terminal client it only sends input and draws the frames the
//! server sends; it is the same protocol drawn with wgpu and glyphon.
//!
//!   imp-gui [FILE...]                 the editor in a window (in-process)
//!   imp-gui --connect [FILE...]       a window on the daemon (imp --daemon)
//!   imp-gui --screenshot OUT.png [--grid 100x30] [--keys KEYS] [FILE...]
//!                                     draw off-screen and save a PNG
//!
//! `--font FAMILY` (default monospace), `--font-file PATH` (repeatable),
//! `--font-size PX` (default 15), `--scale F` (multiplies the size; default
//! $IMP_GUI_SCALE or 1, on top of the display's own scale factor),
//! `--name N` / `--socket PATH` as for imp. In the window, C-= and C--
//! zoom and C-0 resets.

mod keys;
mod render;

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::Duration;

use imp_core::{protocol, Buffer, ClientMsg, Frame, ServerMsg};
use render::{Font, Renderer};
use winit::application::ApplicationHandler;
use winit::event::{ElementState, Modifiers, MouseButton, MouseScrollDelta, WindowEvent};
use winit::event_loop::{ActiveEventLoop, EventLoop, EventLoopProxy};
use winit::window::{Window, WindowId};

#[derive(Default)]
struct Args {
    connect: bool,
    name: Option<String>,
    socket: Option<PathBuf>,
    screenshot: Option<PathBuf>,
    grid: (u16, u16),
    keys: String,
    font: Option<String>,
    font_files: Vec<PathBuf>,
    font_size: f32,
    scale: f32,
    files: Vec<PathBuf>,
}

const USAGE: &str =
    "usage: imp-gui [--font FAMILY] [--font-file PATH] [--font-size PX] [--scale F] [FILE...]
       imp-gui --connect [--name NAME | --socket PATH] [FILE...]
       imp-gui --screenshot OUT.png [--grid COLSxROWS] [--keys KEYS] [FILE...]";

fn parse_args() -> Result<Args, String> {
    let mut args = Args {
        grid: (100, 30),
        font_size: 15.0,
        scale: std::env::var("IMP_GUI_SCALE")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(1.0),
        ..Args::default()
    };
    let mut it = std::env::args_os().skip(1);
    while let Some(arg) = it.next() {
        let mut value = |what: &str| {
            it.next()
                .map(|v| v.to_string_lossy().into_owned())
                .ok_or(format!("{what} needs a value"))
        };
        match arg.to_str() {
            Some("--connect") => args.connect = true,
            Some("--name") => args.name = Some(value("--name")?),
            Some("--socket") => args.socket = Some(value("--socket")?.into()),
            Some("--screenshot") => args.screenshot = Some(value("--screenshot")?.into()),
            Some("--keys") => args.keys = value("--keys")?,
            Some("--font") => args.font = Some(value("--font")?),
            Some("--font-file") => args.font_files.push(value("--font-file")?.into()),
            Some("--font-size") => {
                args.font_size = value("--font-size")?
                    .parse()
                    .map_err(|_| "bad --font-size")?
            }
            Some("--scale") => args.scale = value("--scale")?.parse().map_err(|_| "bad --scale")?,
            Some("--grid") => {
                let grid = value("--grid")?;
                let (w, h) = grid.split_once('x').ok_or("--grid is COLSxROWS")?;
                args.grid = (
                    w.parse().map_err(|_| "bad --grid")?,
                    h.parse().map_err(|_| "bad --grid")?,
                );
            }
            Some("--help" | "-h") => {
                println!("{USAGE}");
                std::process::exit(0);
            }
            Some(flag) if flag.starts_with("--") => {
                return Err(format!("unknown option {flag}\n{USAGE}"))
            }
            _ => args.files.push(arg.into()),
        }
    }
    Ok(args)
}

fn main() {
    let result = parse_args().and_then(|args| {
        if args.screenshot.is_some() {
            screenshot(&args)
        } else {
            window(&args)
        }
    });
    if let Err(e) = result {
        eprintln!("imp-gui: {e}");
        std::process::exit(1);
    }
}

fn font(args: &Args) -> Font {
    Font {
        family: args.font.clone().unwrap_or_else(|| "monospace".into()),
        files: args.font_files.clone(),
        size: args.font_size * args.scale,
    }
}

/// A connection to an editor: messages to it, and a callback-driven
/// stream of what it sends.
struct Connection {
    to_server: mpsc::Sender<ClientMsg>,
}

/// Starts the editor (in-process, or the daemon's socket) and passes
/// everything it sends to `deliver`, on a thread.
fn connect(
    args: &Args,
    deliver: impl Fn(ServerMsg) + Send + 'static,
) -> Result<Connection, String> {
    let (to_server, from_client) = mpsc::channel::<ClientMsg>();
    let (to_client, from_server) = mpsc::channel::<ServerMsg>();
    if args.connect {
        let socket = args.socket.clone().unwrap_or_else(|| {
            imp_server::daemon::socket_path(args.name.as_deref().unwrap_or("default"))
        });
        let stream = std::os::unix::net::UnixStream::connect(&socket).map_err(|e| {
            format!(
                "can't reach a daemon on {} ({e}); start one with imp --daemon",
                socket.display()
            )
        })?;
        let mut writer = stream.try_clone().map_err(|e| e.to_string())?;
        thread::spawn(move || {
            for msg in from_client {
                if writeln!(writer, "{}", protocol::to_line(&msg)).is_err() {
                    break;
                }
            }
        });
        thread::spawn(move || {
            for line in BufReader::new(stream).lines().map_while(Result::ok) {
                if let Ok(msg) = protocol::from_line::<ServerMsg>(&line) {
                    if to_client.send(msg).is_err() {
                        break;
                    }
                }
            }
        });
        let cwd = std::env::current_dir().map_err(|e| e.to_string())?;
        if !args.files.is_empty() {
            let files = args.files.iter().map(|p| cwd.join(p).display().to_string());
            let _ = to_server.send(ClientMsg::Open(files.collect()));
        }
    } else {
        let buffers = args
            .files
            .iter()
            .map(|path| Buffer::open(path).map_err(|e| format!("{}: {e}", path.display())))
            .collect::<Result<Vec<_>, _>>()?;
        let options = imp_server::Options {
            user_config: imp_server::user_config_path(),
        };
        thread::spawn(move || {
            if let Err(e) = imp_server::run(buffers, options, from_client, to_client) {
                eprintln!("imp-gui: {e}");
            }
        });
    }
    thread::spawn(move || {
        for msg in from_server {
            deliver(msg);
        }
        deliver(ServerMsg::Quit);
    });
    Ok(Connection { to_server })
}

/// Applies a message to the screen; false when the editor quit.
fn apply(screen: &mut Frame, msg: ServerMsg) -> bool {
    match msg {
        ServerMsg::Frame(frame) => *screen = frame,
        ServerMsg::Patch(patch) => patch.apply(screen),
        ServerMsg::Quit => return false,
    }
    true
}

async fn device(
    instance: &wgpu::Instance,
    surface: Option<&wgpu::Surface<'_>>,
) -> Result<(wgpu::Adapter, wgpu::Device, wgpu::Queue), String> {
    let adapter = instance
        .request_adapter(&wgpu::RequestAdapterOptions {
            compatible_surface: surface,
            ..Default::default()
        })
        .await
        .map_err(|e| format!("no graphics adapter: {e}"))?;
    let (device, queue) = adapter
        .request_device(&wgpu::DeviceDescriptor::default())
        .await
        .map_err(|e| e.to_string())?;
    Ok((adapter, device, queue))
}

/// Runs the editor off-screen: sends `--keys`, waits for the screen to
/// settle, draws it and saves a PNG.
fn screenshot(args: &Args) -> Result<(), String> {
    let (tx, rx) = mpsc::channel();
    let conn = connect(args, move |msg| {
        let _ = tx.send(msg);
    })?;
    let (cols, rows) = args.grid;
    let _ = conn.to_server.send(ClientMsg::Resize {
        width: cols,
        height: rows,
    });
    let mut screen = Frame::default();
    let settle = |screen: &mut Frame, idle: Duration| {
        while let Ok(msg) = rx.recv_timeout(idle) {
            if !apply(screen, msg) {
                break;
            }
        }
    };
    settle(&mut screen, Duration::from_millis(1500));
    for key in keys::parse_keys(&args.keys) {
        let _ = conn.to_server.send(ClientMsg::Key(key));
    }
    settle(&mut screen, Duration::from_millis(500));

    let instance =
        wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle_from_env());
    let (_, device, queue) = pollster::block_on(device(&instance, None))?;
    let format = wgpu::TextureFormat::Rgba8UnormSrgb;
    let mut renderer = Renderer::new(device, queue, format, &font(args));
    let (width, height) = (
        (cols as f32 * renderer.cell.0).ceil() as u32,
        (rows as f32 * renderer.cell.1).ceil() as u32,
    );
    let texture = renderer.device.create_texture(&wgpu::TextureDescriptor {
        label: Some("screenshot"),
        size: wgpu::Extent3d {
            width,
            height,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
        view_formats: &[],
    });
    let view = texture.create_view(&Default::default());
    renderer.draw(&screen, &view, width, height);

    let row_bytes = (width * 4).div_ceil(256) * 256;
    let buffer = renderer.device.create_buffer(&wgpu::BufferDescriptor {
        label: None,
        size: (row_bytes * height) as u64,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });
    let mut encoder = renderer.device.create_command_encoder(&Default::default());
    encoder.copy_texture_to_buffer(
        texture.as_image_copy(),
        wgpu::TexelCopyBufferInfo {
            buffer: &buffer,
            layout: wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(row_bytes),
                rows_per_image: Some(height),
            },
        },
        texture.size(),
    );
    renderer.queue.submit(Some(encoder.finish()));
    let slice = buffer.slice(..);
    slice.map_async(wgpu::MapMode::Read, |_| {});
    renderer
        .device
        .poll(wgpu::PollType::wait_indefinitely())
        .map_err(|e| e.to_string())?;
    let data = slice.get_mapped_range().map_err(|e| e.to_string())?;
    let pixels: Vec<u8> = data
        .chunks(row_bytes as usize)
        .flat_map(|row| &row[..(width * 4) as usize])
        .copied()
        .collect();

    let out = args.screenshot.as_ref().expect("screenshot mode");
    let file = std::fs::File::create(out).map_err(|e| format!("{}: {e}", out.display()))?;
    let mut png = png::Encoder::new(std::io::BufWriter::new(file), width, height);
    png.set_color(png::ColorType::Rgba);
    png.set_depth(png::BitDepth::Eight);
    png.write_header()
        .and_then(|mut w| w.write_image_data(&pixels))
        .map_err(|e| e.to_string())?;
    let _ = conn.to_server.send(ClientMsg::Key("<esc>".into()));
    Ok(())
}

fn window(args: &Args) -> Result<(), String> {
    let event_loop = EventLoop::<ServerMsg>::with_user_event()
        .build()
        .map_err(|e| e.to_string())?;
    let proxy: EventLoopProxy<ServerMsg> = event_loop.create_proxy();
    let conn = connect(args, move |msg| {
        let _ = proxy.send_event(msg);
    })?;
    let mut app = App {
        conn,
        font: font(args),
        screen: Frame::default(),
        state: None,
        zoom: 1.0,
        modifiers: Modifiers::default(),
        mouse: (0, 0),
        pressed: None,
        scroll: 0.0,
        error: None,
    };
    event_loop.run_app(&mut app).map_err(|e| e.to_string())?;
    app.error.map_or(Ok(()), Err)
}

struct WindowState {
    surface: wgpu::Surface<'static>,
    config: wgpu::SurfaceConfiguration,
    renderer: Renderer,
    grid: (u16, u16),
    // Dropped last: the surface refers to it.
    window: Arc<Window>,
}

struct App {
    conn: Connection,
    font: Font,
    screen: Frame,
    state: Option<WindowState>,
    /// C-= and C-- change this; the font size is multiplied by it.
    zoom: f32,
    modifiers: Modifiers,
    /// The mouse's cell, and the button held down.
    mouse: (u16, u16),
    pressed: Option<&'static str>,
    /// Pixel scrolling not yet a whole line.
    scroll: f64,
    error: Option<String>,
}

impl App {
    fn send(&self, msg: ClientMsg) {
        let _ = self.conn.to_server.send(msg);
    }

    fn open_window(&mut self, event_loop: &ActiveEventLoop) -> Result<(), String> {
        let attrs = Window::default_attributes()
            .with_title("imp")
            .with_inner_size(winit::dpi::LogicalSize::new(1000.0, 650.0));
        let window = Arc::new(event_loop.create_window(attrs).map_err(|e| e.to_string())?);
        let instance =
            wgpu::Instance::new(wgpu::InstanceDescriptor::new_with_display_handle_from_env(
                Box::new(event_loop.owned_display_handle()),
            ));
        let surface = instance
            .create_surface(window.clone())
            .map_err(|e| e.to_string())?;
        let (adapter, device, queue) = pollster::block_on(device(&instance, Some(&surface)))?;
        let caps = surface.get_capabilities(&adapter);
        let format = caps
            .formats
            .iter()
            .copied()
            .find(|f| f.is_srgb())
            .unwrap_or(caps.formats[0]);
        let size = window.inner_size();
        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            width: size.width.max(1),
            height: size.height.max(1),
            present_mode: wgpu::PresentMode::Fifo,
            alpha_mode: caps.alpha_modes[0],
            view_formats: vec![],
            desired_maximum_frame_latency: 2,
            color_space: wgpu::SurfaceColorSpace::Auto,
        };
        surface.configure(&device, &config);
        let font = Font {
            family: self.font.family.clone(),
            files: self.font.files.clone(),
            size: self.font.size * self.zoom * window.scale_factor() as f32,
        };
        let renderer = Renderer::new(device, queue, format, &font);
        let grid = renderer.grid(config.width, config.height);
        self.send(ClientMsg::Resize {
            width: grid.0,
            height: grid.1,
        });
        self.state = Some(WindowState {
            surface,
            config,
            renderer,
            grid,
            window,
        });
        Ok(())
    }

    /// Sets the zoom (1 is the starting size) and redraws at the new size.
    fn set_zoom(&mut self, zoom: f32) {
        self.zoom = zoom.clamp(0.25, 8.0);
        let Some(state) = &mut self.state else { return };
        let scale = state.window.scale_factor() as f32;
        state
            .renderer
            .set_font_size(self.font.size * self.zoom * scale);
        // A new cell size: the grid changes even though the window doesn't.
        state.grid = (0, 0);
        let (w, h) = (state.config.width, state.config.height);
        self.resize(w, h);
    }

    fn resize(&mut self, width: u32, height: u32) {
        let Some(state) = &mut self.state else { return };
        state.config.width = width.max(1);
        state.config.height = height.max(1);
        state
            .surface
            .configure(&state.renderer.device, &state.config);
        let grid = state.renderer.grid(state.config.width, state.config.height);
        state.window.request_redraw();
        if grid != state.grid {
            state.grid = grid;
            let _ = self.conn.to_server.send(ClientMsg::Resize {
                width: grid.0,
                height: grid.1,
            });
        }
    }

    fn redraw(&mut self) {
        let Some(state) = &mut self.state else { return };
        let texture = match state.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(t) => t,
            wgpu::CurrentSurfaceTexture::Outdated
            | wgpu::CurrentSurfaceTexture::Suboptimal(_)
            | wgpu::CurrentSurfaceTexture::Lost => {
                state
                    .surface
                    .configure(&state.renderer.device, &state.config);
                state.window.request_redraw();
                return;
            }
            _ => {
                state.window.request_redraw();
                return;
            }
        };
        let view = texture.texture.create_view(&Default::default());
        let (w, h) = (state.config.width, state.config.height);
        state.renderer.draw(&self.screen, &view, w, h);
        state.window.pre_present_notify();
        state.renderer.queue.present(texture);
    }

    fn mouse(&self, action: &str, button: &str) {
        self.send(ClientMsg::Mouse {
            action: action.into(),
            button: button.into(),
            x: self.mouse.0,
            y: self.mouse.1,
        });
    }
}

impl ApplicationHandler<ServerMsg> for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.state.is_none() {
            if let Err(e) = self.open_window(event_loop) {
                self.error = Some(e);
                event_loop.exit();
            }
        }
    }

    fn user_event(&mut self, event_loop: &ActiveEventLoop, msg: ServerMsg) {
        if !apply(&mut self.screen, msg) {
            event_loop.exit();
            return;
        }
        if let Some(state) = &self.state {
            state.window.request_redraw();
        }
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, _: WindowId, event: WindowEvent) {
        match event {
            WindowEvent::CloseRequested => {
                // As :qa would; the editor asks about unsaved changes.
                self.send(ClientMsg::Key("<esc>".into()));
                for key in keys::parse_keys(":qa<ret>") {
                    self.send(ClientMsg::Key(key));
                }
            }
            WindowEvent::Resized(size) => self.resize(size.width, size.height),
            WindowEvent::RedrawRequested => self.redraw(),
            WindowEvent::ModifiersChanged(m) => self.modifiers = m,
            WindowEvent::ScaleFactorChanged { .. } => self.set_zoom(self.zoom),
            WindowEvent::KeyboardInput { event, .. } if event.state == ElementState::Pressed => {
                let key = keys::key_name(&event, &self.modifiers);
                match key.as_deref() {
                    Some("C-=" | "C-+") => return self.set_zoom(self.zoom * 1.1),
                    Some("C--") => return self.set_zoom(self.zoom / 1.1),
                    Some("C-0") => return self.set_zoom(1.0),
                    _ => {}
                }
                if let Some(key) = key {
                    self.send(ClientMsg::Key(key));
                }
            }
            WindowEvent::CursorMoved { position, .. } => {
                let Some(state) = &self.state else { return };
                let (cw, ch) = state.renderer.cell;
                let cell = (
                    (position.x as f32 / cw).max(0.0) as u16,
                    (position.y as f32 / ch).max(0.0) as u16,
                );
                if cell != self.mouse {
                    self.mouse = cell;
                    if let Some(button) = self.pressed {
                        self.mouse("drag", button);
                    }
                }
            }
            WindowEvent::MouseInput { state, button, .. } => {
                let name = match button {
                    MouseButton::Left => "left",
                    MouseButton::Right => "right",
                    MouseButton::Middle => "middle",
                    _ => return,
                };
                if state == ElementState::Pressed {
                    self.pressed = Some(name);
                    self.mouse("press", name);
                } else {
                    self.pressed = None;
                    self.mouse("release", name);
                }
            }
            WindowEvent::MouseWheel { delta, .. } => {
                let lines = match delta {
                    MouseScrollDelta::LineDelta(_, y) => y as f64,
                    MouseScrollDelta::PixelDelta(p) => {
                        let ch = self.state.as_ref().map_or(20.0, |s| s.renderer.cell.1) as f64;
                        self.scroll += p.y / ch;
                        let whole = self.scroll.trunc();
                        self.scroll -= whole;
                        whole
                    }
                };
                let action = if lines > 0.0 {
                    "scroll-up"
                } else {
                    "scroll-down"
                };
                for _ in 0..lines.abs() as usize {
                    self.mouse(action, "");
                }
            }
            _ => {}
        }
        let _ = event_loop;
    }
}
