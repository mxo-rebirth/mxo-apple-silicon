// d3d9bench: a single-file Direct3D 9 draw-call benchmark and smoke test (no standard library, 32-bit Windows).
// Arguments, modes, output and exit codes: docs/development.md, section "The benchmark".
#![no_std]
#![no_main]

use core::ffi::c_void;
use core::mem::{size_of, transmute, zeroed};
use core::ptr::{null, null_mut, read_volatile, write_volatile};

type P = *mut c_void;

// ---- what the C runtime would provide ------------------------------------------------------------------

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    unsafe { ExitProcess(EXIT_PANIC) }
}

// The MSVC target refers to these for floats and for unwind tables.
#[unsafe(no_mangle)]
pub static _fltused: i32 = 0;
#[unsafe(no_mangle)]
pub extern "C" fn __CxxFrameHandler3() {}

// 64-bit division, which the MSVC target leaves to the C runtime. The timing sums use it.
fn udivmod(mut n: u64, d: u64) -> (u64, u64) {
    if d == 0 {
        return (0, 0);
    }
    let (mut q, mut r) = (0u64, 0u64);
    for _ in 0..64 {
        r = (r << 1) | (n >> 63);
        n <<= 1;
        q <<= 1;
        if r >= d {
            r -= d;
            q |= 1;
        }
    }
    (q, r)
}
unsafe extern "stdcall" fn aulldiv(n: u64, d: u64) -> u64 {
    udivmod(n, d).0
}
unsafe extern "stdcall" fn aullrem(n: u64, d: u64) -> u64 {
    udivmod(n, d).1
}
core::arch::global_asm!(
    ".globl __aulldiv",
    "__aulldiv:",
    "jmp {d}",
    ".globl __aullrem",
    "__aullrem:",
    "jmp {r}",
    d = sym aulldiv,
    r = sym aullrem,
);

// Volatile byte loops, so the compiler cannot turn a loop back into a call to the function it is in.
// The timed copies (modes 2 to 5, the UI vertex buffer) run through this memcpy too.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn memset(d: *mut u8, c: i32, n: usize) -> *mut u8 {
    for i in 0..n {
        write_volatile(d.add(i), c as u8);
    }
    d
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn memcpy(d: *mut u8, s: *const u8, n: usize) -> *mut u8 {
    for i in 0..n {
        write_volatile(d.add(i), read_volatile(s.add(i)));
    }
    d
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn memmove(d: *mut u8, s: *const u8, n: usize) -> *mut u8 {
    if (d as usize) <= (s as usize) {
        return memcpy(d, s, n);
    }
    for i in (0..n).rev() {
        write_volatile(d.add(i), read_volatile(s.add(i)));
    }
    d
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn memcmp(a: *const u8, b: *const u8, n: usize) -> i32 {
    for i in 0..n {
        let (x, y) = (read_volatile(a.add(i)), read_volatile(b.add(i)));
        if x != y {
            return x as i32 - y as i32;
        }
    }
    0
}

// ---- Win32 -----------------------------------------------------------------------------------------------

#[repr(C)]
struct WNDCLASSA {
    style: u32,
    wndproc: unsafe extern "system" fn(P, u32, usize, isize) -> isize,
    cls_extra: i32,
    wnd_extra: i32,
    inst: P,
    icon: P,
    cursor: P,
    bg: P,
    menu: *const u8,
    name: *const u8,
}
#[repr(C)]
struct MSG {
    hwnd: P,
    message: u32,
    wparam: usize,
    lparam: isize,
    time: u32,
    x: i32,
    y: i32,
}
#[repr(C)]
struct RECT {
    l: i32,
    t: i32,
    r: i32,
    b: i32,
}

#[link(name = "kernel32", kind = "raw-dylib", import_name_type = "undecorated")]
unsafe extern "system" {
    fn ExitProcess(code: u32) -> !;
    fn GetStdHandle(n: u32) -> P;
    fn WriteFile(h: P, buf: *const u8, n: u32, written: *mut u32, ov: P) -> i32;
    fn GetTickCount() -> u32;
    fn GetModuleHandleA(n: *const u8) -> P;
    fn GetCommandLineA() -> *const u8;
    fn QueryPerformanceCounter(v: *mut i64) -> i32;
    fn QueryPerformanceFrequency(v: *mut i64) -> i32;
}
#[link(name = "user32", kind = "raw-dylib", import_name_type = "undecorated")]
unsafe extern "system" {
    fn RegisterClassA(wc: *const WNDCLASSA) -> u16;
    fn CreateWindowExA(
        ex: u32, cls: *const u8, name: *const u8, style: u32, x: i32, y: i32, w: i32, h: i32,
        parent: P, menu: P, inst: P, param: P,
    ) -> P;
    fn DefWindowProcA(h: P, m: u32, w: usize, l: isize) -> isize;
    fn PeekMessageA(msg: *mut MSG, h: P, min: u32, max: u32, remove: u32) -> i32;
    fn TranslateMessage(msg: *const MSG) -> i32;
    fn DispatchMessageA(msg: *const MSG) -> isize;
    fn AdjustWindowRect(r: *mut RECT, style: u32, menu: i32) -> i32;
    fn SetForegroundWindow(h: P) -> i32;
}
#[link(name = "d3d9", kind = "raw-dylib", import_name_type = "undecorated")]
unsafe extern "system" {
    fn Direct3DCreate9(sdk: u32) -> P;
}

const STD_OUTPUT_HANDLE: u32 = 0xFFFF_FFF5;
const PM_REMOVE: u32 = 1;
const WS_POPUP: u32 = 0x8000_0000;
const WS_VISIBLE: u32 = 0x1000_0000;
const WS_CAPTION: u32 = 0x00C0_0000;
const WS_SYSMENU: u32 = 0x0008_0000;
const WS_MINIMIZEBOX: u32 = 0x0002_0000;
const WS_EX_TOPMOST: u32 = 8;

const EXIT_BAD_ARGUMENTS: u32 = 1;
const EXIT_NO_WINDOW: u32 = 2;
const EXIT_NO_DIRECT3D: u32 = 3;
const EXIT_NO_DEVICE: u32 = 4;
const EXIT_CALL_FAILED: u32 = 6;
const EXIT_PANIC: u32 = 99;

// ---- Direct3D 9 ------------------------------------------------------------------------------------------

/// D3DPRESENT_PARAMETERS
#[repr(C)]
struct PresentParams {
    width: u32,
    height: u32,
    format: u32,
    count: u32,
    multisample: u32,
    multisample_quality: u32,
    swap_effect: u32,
    window: P,
    windowed: i32,
    auto_depth_stencil: i32,
    depth_stencil_format: u32,
    flags: u32,
    refresh_rate: u32,
    interval: u32,
}
/// D3DLOCKED_RECT
#[repr(C)]
struct LockedRect {
    pitch: i32,
    bits: *mut u8,
}
impl LockedRect {
    const EMPTY: LockedRect = LockedRect { pitch: 0, bits: null_mut() };
}
/// D3DLIGHT9
#[repr(C)]
struct Light {
    kind: u32,
    diffuse: [f32; 4],
    specular: [f32; 4],
    ambient: [f32; 4],
    position: [f32; 3],
    direction: [f32; 3],
    range: f32,
    falloff: f32,
    attenuation: [f32; 3],
    theta: f32,
    phi: f32,
}
/// D3DMATERIAL9
#[repr(C)]
struct Material {
    diffuse: [f32; 4],
    ambient: [f32; 4],
    specular: [f32; 4],
    emissive: [f32; 4],
    power: f32,
}
/// A UI vertex, laid out as FVF_UI.
#[repr(C)]
#[derive(Clone, Copy)]
struct UiVert {
    x: f32,
    y: f32,
    z: f32,
    rhw: f32,
    c: u32,
    u: f32,
    v: f32,
}

// Direct3D reads these as they are laid out here.
const _: () = assert!(size_of::<PresentParams>() == 56);
const _: () = assert!(size_of::<LockedRect>() == 8);
const _: () = assert!(size_of::<Light>() == 104);
const _: () = assert!(size_of::<Material>() == 68);
const _: () = assert!(size_of::<UiVert>() == UI_STRIDE as usize);

// Values of d3d9.h and d3d9types.h, named as there without the D3D prefix.
const SDK_VERSION: u32 = 32;
const ADAPTER_DEFAULT: u32 = 0;
const DEVTYPE_HAL: u32 = 1;
const CREATE_SOFTWARE_VERTEXPROCESSING: u32 = 0x20;
const CREATE_HARDWARE_VERTEXPROCESSING: u32 = 0x40;
const CREATE_MIXED_VERTEXPROCESSING: u32 = 0x80;
const SWAPEFFECT_DISCARD: u32 = 1;
const PRESENT_INTERVAL_IMMEDIATE: u32 = 0x8000_0000;
const FMT_A8R8G8B8: u32 = 21;
const FMT_X8R8G8B8: u32 = 22;
const FMT_D24S8: u32 = 75;
const FMT_INDEX16: u32 = 101;
const FMT_DXT1: u32 = 0x3154_5844;
const POOL_DEFAULT: u32 = 0;
const POOL_MANAGED: u32 = 1;
const POOL_SYSTEMMEM: u32 = 2;
const USAGE_WRITEONLY: u32 = 0x8;
const USAGE_DYNAMIC: u32 = 0x200;
const LOCK_READONLY: u32 = 0x10;
const LOCK_NOOVERWRITE: u32 = 0x1000;
const LOCK_DISCARD: u32 = 0x2000;
const FVF_XYZ: u32 = 0x002;
const FVF_XYZRHW: u32 = 0x004;
const FVF_NORMAL: u32 = 0x010;
const FVF_DIFFUSE: u32 = 0x040;
const FVF_TEX1: u32 = 0x100;
const CLEAR_TARGET: u32 = 1;
const CLEAR_ZBUFFER: u32 = 2;
const TS_VIEW: u32 = 2;
const TS_PROJECTION: u32 = 3;
const TS_WORLD: u32 = 256;
const RS_ZENABLE: u32 = 7;
const RS_SRCBLEND: u32 = 19;
const RS_DESTBLEND: u32 = 20;
const RS_CULLMODE: u32 = 22;
const RS_ALPHABLENDENABLE: u32 = 27;
const RS_LIGHTING: u32 = 137;
const RS_AMBIENT: u32 = 139;
const BLEND_SRCALPHA: u32 = 5;
const BLEND_INVSRCALPHA: u32 = 6;
const CULL_NONE: u32 = 1;
const SAMP_MAGFILTER: u32 = 5;
const SAMP_MINFILTER: u32 = 6;
const TEXF_LINEAR: u32 = 2;
const TSS_COLOROP: u32 = 1;
const TSS_COLORARG1: u32 = 2;
const TSS_COLORARG2: u32 = 3;
const TSS_ALPHAOP: u32 = 4;
const TSS_ALPHAARG1: u32 = 5;
const TSS_ALPHAARG2: u32 = 6;
const TOP_MODULATE: u32 = 4;
const TA_DIFFUSE: u32 = 0;
const TA_TEXTURE: u32 = 2;
const PT_TRIANGLELIST: u32 = 4;
const PT_TRIANGLESTRIP: u32 = 5;
const LIGHT_DIRECTIONAL: u32 = 3;

/// Each Direct3D method the benchmark calls, once, with its vtable slot (the order of d3d9.h) and its
/// signature, so a call site cannot pair a slot with the wrong arguments.
mod d3d {
    use super::{transmute, Light, LockedRect, Material, PresentParams, UiVert, P};

    macro_rules! methods {
        ($($name:ident = $slot:literal ($($a:ident: $t:ty),*);)*) => {$(
            #[inline(always)]
            pub unsafe fn $name(this: P $(, $a: $t)*) -> i32 {
                let slot = *(*(this as *const *const P)).add($slot);
                let f: unsafe extern "system" fn(P $(, $t)*) -> i32 = transmute(slot);
                f(this $(, $a)*)
            }
        )*};
    }

    methods! {
        // IDirect3D9
        create_device = 16 (adapter: u32, kind: u32, focus: P, flags: u32, params: *mut PresentParams, out: *mut P);
        // IDirect3DDevice9
        present = 17 (src: P, dst: P, window: P, dirty: P);
        create_texture = 23 (w: u32, h: u32, levels: u32, usage: u32, format: u32, pool: u32, out: *mut P, shared: P);
        create_vertex_buffer = 26 (bytes: u32, usage: u32, fvf: u32, pool: u32, out: *mut P, shared: P);
        get_render_target_data = 32 (target: P, dst: P);
        create_offscreen_plain_surface = 36 (w: u32, h: u32, format: u32, pool: u32, out: *mut P, shared: P);
        get_render_target = 38 (index: u32, out: *mut P);
        begin_scene = 41 ();
        end_scene = 42 ();
        clear = 43 (count: u32, rects: P, flags: u32, color: u32, z: f32, stencil: u32);
        set_transform = 44 (state: u32, matrix: *const f32);
        set_material = 49 (material: *const Material);
        set_light = 51 (index: u32, light: *const Light);
        light_enable = 53 (index: u32, on: i32);
        set_render_state = 57 (state: u32, value: u32);
        set_texture = 65 (stage: u32, texture: P);
        set_texture_stage_state = 67 (stage: u32, state: u32, value: u32);
        set_sampler_state = 69 (sampler: u32, state: u32, value: u32);
        draw_primitive = 81 (kind: u32, first_vertex: u32, count: u32);
        draw_primitive_up = 83 (kind: u32, count: u32, vertices: *const UiVert, stride: u32);
        draw_indexed_primitive_up = 84 (kind: u32, min_index: u32, vertex_count: u32, count: u32,
            indices: *const u16, index_format: u32, vertices: *const f32, stride: u32);
        set_fvf = 89 (fvf: u32);
        create_vertex_shader = 91 (code: *const u32, out: *mut P);
        set_vertex_shader = 92 (shader: P);
        set_vertex_shader_constant_f = 94 (first: u32, data: *const f32, vectors: u32);
        set_stream_source = 100 (stream: u32, buffer: P, offset: u32, stride: u32);
        create_pixel_shader = 106 (code: *const u32, out: *mut P);
        set_pixel_shader = 107 (shader: P);
        // IDirect3DVertexBuffer9
        vb_lock = 11 (offset: u32, size: u32, data: *mut *mut u8, flags: u32);
        vb_unlock = 12 ();
        // IDirect3DTexture9
        tex_lock_rect = 19 (level: u32, locked: *mut LockedRect, rect: P, flags: u32);
        tex_unlock_rect = 20 (level: u32);
        // IDirect3DSurface9
        surface_lock_rect = 13 (locked: *mut LockedRect, rect: P, flags: u32);
    }
}

// ---- what the benchmark draws ----------------------------------------------------------------------------

/// What each world draw does: the last argument.
mod mode {
    pub const SHADER: u32 = 1;
    pub const LOCK: u32 = 2;
    pub const APPEND: u32 = 3;
    pub const LOCK_DISCARD: u32 = 4;
    pub const LOCK_MANAGED: u32 = 5;
    pub const TOUCH_TEXTURE: u32 = 6;
    pub const INDEXED_UP: u32 = 7;
    pub const SHADER_PS11: u32 = 8;
    pub const SHADER_PS20: u32 = 9;
    pub const STREAM: u32 = 10;
    pub const STREAM_DRAW: u32 = 11;

    pub fn uses_vertex_shader(mode: u32) -> bool {
        matches!(mode, SHADER | SHADER_PS11 | SHADER_PS20)
    }
    pub fn streams_textures(mode: u32) -> bool {
        matches!(mode, STREAM | STREAM_DRAW)
    }
}

/// How the UI quads are drawn.
#[derive(Clone, Copy, PartialEq)]
enum Ui {
    UserPointer,
    VertexBuffer,
    None,
}

const CLEAR_COLOR: u32 = 0xFF20_3040;
const RGB: u32 = 0x00FF_FFFF;
const WHITE: u32 = 0xFFFF_FFFF;
const MAGENTA: u32 = 0xFFFF_00FF;
/// The dark squares of the two checkerboard textures.
const DARK: [u32; 2] = [0xFFB0_B0B0, 0xFF80_C0FF];
const DARK_RGB565: [u16; 2] = [0xB596, 0x861F];

const FVF_WORLD: u32 = FVF_XYZ | FVF_NORMAL | FVF_TEX1;
const FVF_UI: u32 = FVF_XYZRHW | FVF_DIFFUSE | FVF_TEX1;
const WORLD_STRIDE: u32 = 32; // position, normal, texture coordinate: 8 floats
const UI_STRIDE: u32 = 28;
const QUAD_BYTES: u32 = 6 * WORLD_STRIDE;
const UI_QUAD_BYTES: u32 = 4 * UI_STRIDE;
const UI_QUADS: u32 = 24;
const DYNAMIC_QUADS: u32 = 4096;
const MANAGED_QUADS: u32 = 16;
const SPARE_TEXTURES: usize = 2048;
const TEX_SIZE: u32 = 64;
const TEX_CELL: usize = 8;
const STREAM_LEVELS: u32 = 3;
const WARM_UP_MS: u32 = 1500;
/// Larger back buffers are refused: a backend that accepts one anyway hands back memory that is not there.
const MAX_SIZE: u32 = 16384;

/// The UI row: UI_QUADS squares along the bottom edge. draw_ui places them, check_pixels reads their middles.
const UI_LEFT: u32 = 10;
const UI_PITCH: u32 = 34;
const UI_QUAD_SIZE: u32 = 28;
/// From the top of the UI quads to the bottom edge of the picture.
const UI_ROW_HEIGHT: u32 = 44;
/// What check_pixels leaves to the UI at the bottom: the row and some room above it.
const UI_AREA_HEIGHT: u32 = 60;
/// check_pixels reads the world at the middles of a grid of this many cells each way.
const WORLD_GRID: u32 = 16;
/// Smaller back buffers are refused: check_pixels would read past a row, or past the picture.
const MIN_WIDTH: u32 = 2 * UI_LEFT + (UI_QUADS - 1) * UI_PITCH + UI_QUAD_SIZE;
const MIN_HEIGHT: u32 = 100;
// docs/development.md names this size.
const _: () = assert!(MIN_WIDTH == 830 && MIN_HEIGHT > UI_AREA_HEIGHT);

/// The world is walls of WALL_COLUMNS x WALL_ROWS meshes, one wall behind the other.
const WALL_COLUMNS: u32 = 64;
const WALL_ROWS: u32 = 36;
/// Between the middles of two meshes. A mesh is one unit across.
const WALL_PITCH: f32 = 1.15;
/// From the camera to the first wall, and from one wall to the next.
const WALL_DISTANCE: f32 = 36.0;
const WALL_SPACING: f32 = 4.0;
/// The world changes its texture every so many draws, and the streaming modes fill one as often.
const TEXTURE_RUN: u32 = 8;

const GRID: usize = 8;
const MESH_VERTS: usize = GRID * GRID * 6;
const MESH_FLOATS: usize = MESH_VERTS * 8;
const MESH_TRIANGLES: u32 = (MESH_VERTS / 3) as u32;
/// GRID x GRID quads in the XY plane, one unit across, facing the camera.
static MESH: [f32; MESH_FLOATS] = mesh();

const fn mesh() -> [f32; MESH_FLOATS] {
    let mut m = [0.0f32; MESH_FLOATS];
    let s = 1.0 / GRID as f32;
    let mut n = 0;
    let mut gy = 0;
    while gy < GRID {
        let mut gx = 0;
        while gx < GRID {
            let (x0, y0) = (gx as f32 * s - 0.5, gy as f32 * s - 0.5);
            let (x1, y1) = (x0 + s, y0 + s);
            let corners = [(x0, y0), (x0, y1), (x1, y0), (x1, y0), (x0, y1), (x1, y1)];
            let mut k = 0;
            while k < 6 {
                let (x, y) = corners[k];
                let o = n * 8;
                m[o] = x;
                m[o + 1] = y;
                m[o + 5] = -1.0;
                m[o + 6] = x + 0.5;
                m[o + 7] = y + 0.5;
                n += 1;
                k += 1;
            }
            gx += 1;
        }
        gy += 1;
    }
    m
}

static QUAD: [f32; 48] = [
    -0.5, -0.5, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, -0.5, 0.5, 0.0, 0.0, 0.0, -1.0, 0.0, 1.0,
    0.5, -0.5, 0.0, 0.0, 0.0, -1.0, 1.0, 0.0, 0.5, -0.5, 0.0, 0.0, 0.0, -1.0, 1.0, 0.0,
    -0.5, 0.5, 0.0, 0.0, 0.0, -1.0, 0.0, 1.0, 0.5, 0.5, 0.0, 0.0, 0.0, -1.0, 1.0, 1.0,
];
static QUAD_INDEXED: [f32; 32] = [
    -0.5, -0.5, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, -0.5, 0.5, 0.0, 0.0, 0.0, -1.0, 0.0, 1.0,
    0.5, -0.5, 0.0, 0.0, 0.0, -1.0, 1.0, 0.0, 0.5, 0.5, 0.0, 0.0, 0.0, -1.0, 1.0, 1.0,
];
static QUAD_INDICES: [u16; 6] = [0, 1, 2, 2, 1, 3];

// vs_1_1: dcl_position v0 / dcl_normal v1 / dcl_texcoord v2 / m4x4 oPos, v0, c0 / mov oT0, v2 / mov oD0, c4
static VS_CODE: [u32; 21] = [
    0xFFFE0101, 0x0000001F, 0x80000000, 0x900F0000, 0x0000001F, 0x80000003, 0x900F0001,
    0x0000001F, 0x80000005, 0x900F0002, 0x00000014, 0xC00F0000, 0x90E40000, 0xA0E40000,
    0x00000001, 0xE00F0000, 0x90E40002, 0x00000001, 0xD00F0000, 0xA0E40004, 0x0000FFFF,
];
// ps_1_1: tex t0 / mul r0, t0, v0
static PS11_CODE: [u32; 8] =
    [0xFFFF0101, 0x00000042, 0xB00F0000, 0x00000005, 0x800F0000, 0xB0E40000, 0x90E40000, 0x0000FFFF];
// ps_2_0: dcl t0.xy / dcl_2d s0 / texld r0, t0, s0 / mov oC0, r0
static PS20_CODE: [u32; 15] = [
    0xFFFF0200, 0x0200001F, 0x80000000, 0xB0030000, 0x0200001F, 0x90000000, 0xA00F0800, 0x03000042,
    0x800F0000, 0xB0E40000, 0xA0E40800, 0x02000001, 0x800F0800, 0x80E40000, 0x0000FFFF,
];

/// Performance-counter ticks per part of a frame, summed over the timed run.
struct Timing {
    clear: u64,
    begin: u64,
    world: u64,
    ui: u64,
    end: u64,
    scene: u64,
    present: u64,
    ui_state: u64,
    ui_first_quad: u64,
    ui_other_quads: u64,
}
impl Timing {
    const ZERO: Timing = Timing {
        clear: 0,
        begin: 0,
        world: 0,
        ui: 0,
        end: 0,
        scene: 0,
        present: 0,
        ui_state: 0,
        ui_first_quad: 0,
        ui_other_quads: 0,
    };
}

/// Everything a frame needs besides the device.
struct Bench {
    mode: u32,
    ui: Ui,
    height: u32,
    draws: u32,
    mesh_vb: P,
    dynamic_vb: P,
    managed_vb: P,
    ui_vb: P,
    textures: [P; 2],
    spare: [P; SPARE_TEXTURES],
    spare_next: usize,
    vertex_shader: P,
    pixel_shaders: [P; 2],
    proj: [f32; 4],
    time: Timing,
}

// A static: too large for the stack without the C runtime's stack probe. main makes the one reference to it.
static mut BENCH: Bench = Bench {
    mode: 0,
    ui: Ui::UserPointer,
    height: 0,
    draws: 0,
    mesh_vb: null_mut(),
    dynamic_vb: null_mut(),
    managed_vb: null_mut(),
    ui_vb: null_mut(),
    textures: [null_mut(); 2],
    spare: [null_mut(); SPARE_TEXTURES],
    spare_next: 0,
    vertex_shader: null_mut(),
    pixel_shaders: [null_mut(); 2],
    proj: [0.0; 4],
    time: Timing::ZERO,
};

struct Options {
    vertex_processing: u32,
    width: u32,
    height: u32,
    draws: u32,
    seconds: u32,
    dxt1: bool,
    topmost: bool,
    ui: Ui,
    fullscreen: bool,
    mode: u32,
}

// ---- output ----------------------------------------------------------------------------------------------

unsafe fn print(s: &[u8]) {
    let mut written = 0u32;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s.as_ptr(), s.len() as u32, &mut written, null_mut());
}
unsafe fn print_u32(mut v: u32) {
    let mut b = [b'0'; 10];
    let mut i = 10;
    loop {
        i -= 1;
        b[i] = b'0' + (v % 10) as u8;
        v /= 10;
        if v == 0 {
            break;
        }
    }
    print(&b[i..]);
}
unsafe fn print_hex(v: u32) {
    let digits = b"0123456789abcdef";
    let mut b = [0u8; 8];
    for (i, d) in b.iter_mut().enumerate() {
        *d = digits[((v >> (28 - 4 * i)) & 15) as usize];
    }
    print(b"0x");
    print(&b);
}
unsafe fn field(label: &[u8], v: u32) {
    print(label);
    print_u32(v);
}

/// Reports a failed call. Direct3D marks failure with a negative result. True if it failed.
unsafe fn report(name: &[u8], hr: i32) -> bool {
    if hr < 0 {
        print(b"  FAIL ");
        print(name);
        print(b" hr=");
        print_hex(hr as u32);
        print(b"\n");
    }
    hr < 0
}
/// For a call the run depends on: what follows would use a null pointer or measure something else.
unsafe fn require(name: &[u8], hr: i32) {
    if report(name, hr) {
        ExitProcess(EXIT_CALL_FAILED);
    }
}
unsafe fn require_if(needed: bool, name: &[u8], hr: i32) {
    if report(name, hr) && needed {
        ExitProcess(EXIT_CALL_FAILED);
    }
}
unsafe fn require_pointer(name: &[u8], p: *const u8) {
    if p.is_null() {
        print(b"  FAIL ");
        print(name);
        print(b" gave no memory\n");
        ExitProcess(EXIT_CALL_FAILED);
    }
}

// ---- setup -----------------------------------------------------------------------------------------------

/// Up to eight numbers after the program's name. Whatever follows the digits of an argument is skipped.
unsafe fn numbers_from_command_line(out: &mut [u32; 8]) {
    let mut p = GetCommandLineA();
    if *p == b'"' {
        p = p.add(1);
        while *p != 0 && *p != b'"' {
            p = p.add(1);
        }
        if *p != 0 {
            p = p.add(1);
        }
    } else {
        while *p != 0 && *p != b' ' {
            p = p.add(1);
        }
    }
    for slot in out.iter_mut() {
        while *p == b' ' {
            p = p.add(1);
        }
        if *p == 0 {
            break;
        }
        let mut v = 0u32;
        while (*p).is_ascii_digit() {
            v = v.wrapping_mul(10).wrapping_add((*p - b'0') as u32);
            p = p.add(1);
        }
        while *p != 0 && *p != b' ' {
            p = p.add(1);
        }
        *slot = v;
    }
}

unsafe fn options() -> Options {
    let mut a = [0u32, 1280, 720, 2000, 4, 0, 0, 0];
    numbers_from_command_line(&mut a);
    let flags = a[6];
    Options {
        vertex_processing: a[0],
        width: a[1],
        height: a[2],
        draws: a[3],
        seconds: a[4],
        dxt1: a[5] == 1,
        topmost: flags & 1 != 0,
        ui: match (flags >> 1) & 3 {
            0 => Ui::UserPointer,
            1 => Ui::VertexBuffer,
            _ => Ui::None,
        },
        fullscreen: flags & 8 != 0,
        mode: a[7],
    }
}

unsafe extern "system" fn wndproc(h: P, m: u32, w: usize, l: isize) -> isize {
    DefWindowProcA(h, m, w, l)
}

unsafe fn pump() {
    let mut m: MSG = zeroed();
    while PeekMessageA(&mut m, null_mut(), 0, 0, PM_REMOVE) != 0 {
        TranslateMessage(&m);
        DispatchMessageA(&m);
    }
}

unsafe fn create_window(o: &Options) -> P {
    let instance = GetModuleHandleA(null());
    let class = b"d3d9bench\0";
    let wc = WNDCLASSA {
        style: 0,
        wndproc,
        cls_extra: 0,
        wnd_extra: 0,
        inst: instance,
        icon: null_mut(),
        cursor: null_mut(),
        bg: null_mut(),
        menu: null(),
        name: class.as_ptr(),
    };
    RegisterClassA(&wc);
    let style = if o.fullscreen { WS_POPUP | WS_VISIBLE } else { WS_VISIBLE | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX };
    let mut r = RECT { l: 0, t: 0, r: o.width as i32, b: o.height as i32 };
    AdjustWindowRect(&mut r, style, 0);
    let window = CreateWindowExA(
        if o.topmost { WS_EX_TOPMOST } else { 0 },
        class.as_ptr(),
        b"d3d9 backend test\0".as_ptr(),
        style,
        60,
        80,
        r.r - r.l,
        r.b - r.t,
        null_mut(),
        null_mut(),
        instance,
        null_mut(),
    );
    if window.is_null() {
        print(b"FAIL CreateWindow\n");
        ExitProcess(EXIT_NO_WINDOW);
    }
    if o.topmost {
        SetForegroundWindow(window);
    }
    pump();
    window
}

unsafe fn create_device(o: &Options, window: P) -> P {
    let d3d9 = Direct3DCreate9(SDK_VERSION);
    if d3d9.is_null() {
        print(b"FAIL Direct3DCreate9\n");
        ExitProcess(EXIT_NO_DIRECT3D);
    }
    let mut params = PresentParams {
        width: o.width,
        height: o.height,
        format: FMT_X8R8G8B8,
        count: 1,
        multisample: 0,
        multisample_quality: 0,
        swap_effect: SWAPEFFECT_DISCARD,
        window,
        windowed: !o.fullscreen as i32,
        auto_depth_stencil: 1,
        depth_stencil_format: FMT_D24S8,
        flags: 0,
        refresh_rate: 0,
        interval: PRESENT_INTERVAL_IMMEDIATE,
    };
    let vertex_processing = match o.vertex_processing {
        0 => CREATE_HARDWARE_VERTEXPROCESSING,
        1 => CREATE_SOFTWARE_VERTEXPROCESSING,
        _ => CREATE_MIXED_VERTEXPROCESSING,
    };
    let mut dev: P = null_mut();
    let hr = d3d::create_device(d3d9, ADAPTER_DEFAULT, DEVTYPE_HAL, window, vertex_processing, &mut params, &mut dev);
    if hr < 0 || dev.is_null() {
        print(b"FAIL CreateDevice hr=");
        print_hex(hr as u32);
        print(b"\n");
        ExitProcess(EXIT_NO_DEVICE);
    }
    dev
}

/// Expects a locked A8R8G8B8 image.
unsafe fn checkerboard(r: &LockedRect, size: usize, cell: usize, light: u32, dark: u32) {
    for y in 0..size {
        for x in 0..size {
            let colour = if (x / cell + y / cell) % 2 == 0 { light } else { dark };
            *(r.bits.add(y * r.pitch as usize + x * 4) as *mut u32) = colour;
        }
    }
}

/// The same checkerboard as DXT1: blocks of 4 x 4 pixels in 8 bytes, two RGB565 colours and 16 two-bit
/// indices, here all zero for the first colour.
unsafe fn checkerboard_dxt1(r: &LockedRect, dark: u16) {
    let blocks = TEX_SIZE as usize / 4;
    for by in 0..blocks {
        for bx in 0..blocks {
            let colour: u16 = if (bx / 2 + by / 2) % 2 == 0 { 0xFFFF } else { dark };
            let block = r.bits.add(by * r.pitch as usize + bx * 8);
            *(block as *mut u16) = colour;
            *(block.add(2) as *mut u16) = colour;
            *(block.add(4) as *mut u32) = 0;
        }
    }
}

/// What the chosen mode draws with must exist. The failure of anything else is only reported.
unsafe fn create_resources(b: &mut Bench, dev: P, o: &Options) {
    let format = if o.dxt1 { FMT_DXT1 } else { FMT_A8R8G8B8 };
    for t in 0..2 {
        let texture = &mut b.textures[t];
        require(b"CreateTexture", d3d::create_texture(dev, TEX_SIZE, TEX_SIZE, 1, 0, format, POOL_MANAGED, texture, null_mut()));
        let mut r = LockedRect::EMPTY;
        require(b"Tex.LockRect", d3d::tex_lock_rect(*texture, 0, &mut r, null_mut(), 0));
        require_pointer(b"Tex.LockRect", r.bits);
        if o.dxt1 {
            checkerboard_dxt1(&r, DARK_RGB565[t]);
        } else {
            checkerboard(&r, TEX_SIZE as usize, TEX_CELL, WHITE, DARK[t]);
        }
        require(b"Tex.UnlockRect", d3d::tex_unlock_rect(*texture, 0));
    }

    let bytes = (MESH_FLOATS * size_of::<f32>()) as u32;
    require(
        b"CreateVertexBuffer",
        d3d::create_vertex_buffer(dev, bytes, USAGE_WRITEONLY, FVF_WORLD, POOL_MANAGED, &mut b.mesh_vb, null_mut()),
    );
    let mut dst: *mut u8 = null_mut();
    require(b"VB.Lock", d3d::vb_lock(b.mesh_vb, 0, bytes, &mut dst, 0));
    require_pointer(b"VB.Lock", dst);
    memcpy(dst, MESH.as_ptr() as *const u8, bytes as usize);
    require(b"VB.Unlock", d3d::vb_unlock(b.mesh_vb));

    let dynamic = USAGE_DYNAMIC | USAGE_WRITEONLY;
    require_if(
        matches!(b.mode, mode::LOCK | mode::APPEND | mode::LOCK_DISCARD),
        b"CreateVertexBuffer(dyn)",
        d3d::create_vertex_buffer(dev, QUAD_BYTES * DYNAMIC_QUADS, dynamic, FVF_WORLD, POOL_DEFAULT, &mut b.dynamic_vb, null_mut()),
    );
    if mode::streams_textures(b.mode) {
        for spare in b.spare.iter_mut() {
            require(
                b"CreateTexture(spare)",
                d3d::create_texture(dev, TEX_SIZE, TEX_SIZE, STREAM_LEVELS, 0, FMT_A8R8G8B8, POOL_MANAGED, spare, null_mut()),
            );
        }
    }
    require_if(
        b.mode == mode::LOCK_MANAGED,
        b"CreateVertexBuffer(managed)",
        d3d::create_vertex_buffer(dev, QUAD_BYTES * MANAGED_QUADS, USAGE_WRITEONLY, FVF_WORLD, POOL_MANAGED, &mut b.managed_vb, null_mut()),
    );
    require_if(
        mode::uses_vertex_shader(b.mode),
        b"CreateVertexShader",
        d3d::create_vertex_shader(dev, VS_CODE.as_ptr(), &mut b.vertex_shader),
    );
    require_if(
        b.mode == mode::SHADER_PS11,
        b"CreatePixelShader(ps_1_1)",
        d3d::create_pixel_shader(dev, PS11_CODE.as_ptr(), &mut b.pixel_shaders[0]),
    );
    require_if(
        b.mode == mode::SHADER_PS20,
        b"CreatePixelShader(ps_2_0)",
        d3d::create_pixel_shader(dev, PS20_CODE.as_ptr(), &mut b.pixel_shaders[1]),
    );
    require_if(
        b.ui == Ui::VertexBuffer,
        b"CreateVertexBuffer(ui)",
        d3d::create_vertex_buffer(dev, UI_QUAD_BYTES, dynamic, FVF_UI, POOL_DEFAULT, &mut b.ui_vb, null_mut()),
    );
}

/// The state that stays as it is for the whole run.
unsafe fn set_fixed_state(b: &mut Bench, dev: P, o: &Options) {
    let ys = 1.7320508f32; // 60 degrees of vertical field of view
    let xs = ys * o.height as f32 / o.width as f32;
    let (zn, zf) = (1.0f32, 2000.0f32);
    let (zscale, zoffset) = (zf / (zf - zn), -zn * zf / (zf - zn));
    b.proj = [xs, ys, zscale, zoffset];
    let proj: [f32; 16] = [xs, 0.0, 0.0, 0.0, 0.0, ys, 0.0, 0.0, 0.0, 0.0, zscale, 1.0, 0.0, 0.0, zoffset, 0.0];
    let identity: [f32; 16] = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0];
    d3d::set_transform(dev, TS_PROJECTION, proj.as_ptr());
    d3d::set_transform(dev, TS_VIEW, identity.as_ptr());

    let light = Light {
        kind: LIGHT_DIRECTIONAL,
        diffuse: [1.0; 4],
        specular: [0.0; 4],
        ambient: [0.0; 4],
        position: [0.0; 3],
        direction: [0.3, -0.3, 1.0],
        range: 0.0,
        falloff: 0.0,
        attenuation: [0.0; 3],
        theta: 0.0,
        phi: 0.0,
    };
    report(b"SetLight", d3d::set_light(dev, 0, &light));
    d3d::light_enable(dev, 0, 1);
    let material = Material { diffuse: [1.0; 4], ambient: [1.0; 4], specular: [0.0; 4], emissive: [0.0; 4], power: 0.0 };
    d3d::set_material(dev, &material);
    d3d::set_render_state(dev, RS_AMBIENT, 0x0040_4040);
    d3d::set_render_state(dev, RS_CULLMODE, CULL_NONE);
    d3d::set_sampler_state(dev, 0, SAMP_MAGFILTER, TEXF_LINEAR);
    d3d::set_sampler_state(dev, 0, SAMP_MINFILTER, TEXF_LINEAR);
    d3d::set_texture_stage_state(dev, 0, TSS_COLOROP, TOP_MODULATE);
    d3d::set_texture_stage_state(dev, 0, TSS_COLORARG1, TA_TEXTURE);
    d3d::set_texture_stage_state(dev, 0, TSS_COLORARG2, TA_DIFFUSE);
    d3d::set_texture_stage_state(dev, 0, TSS_ALPHAOP, TOP_MODULATE);
    d3d::set_texture_stage_state(dev, 0, TSS_ALPHAARG1, TA_TEXTURE);
    d3d::set_texture_stage_state(dev, 0, TSS_ALPHAARG2, TA_DIFFUSE);
}

// ---- a frame ---------------------------------------------------------------------------------------------

unsafe fn ticks() -> u64 {
    let mut v: i64 = 0;
    QueryPerformanceCounter(&mut v);
    v as u64
}

unsafe fn write_quad(buffer: P, offset: u32, flags: u32) {
    let mut dst: *mut u8 = null_mut();
    d3d::vb_lock(buffer, offset, QUAD_BYTES, &mut dst, flags);
    if !dst.is_null() {
        memcpy(dst, QUAD.as_ptr() as *const u8, QUAD_BYTES as usize);
    }
    d3d::vb_unlock(buffer);
}

/// The "world": lit meshes or quads, one draw call each, as the mode says.
unsafe fn draw_world(b: &mut Bench, dev: P, readback: bool) {
    d3d::set_fvf(dev, FVF_WORLD);
    d3d::set_stream_source(dev, 0, b.mesh_vb, 0, WORLD_STRIDE);
    d3d::set_render_state(dev, RS_LIGHTING, 1);
    d3d::set_render_state(dev, RS_ZENABLE, 1);
    d3d::set_render_state(dev, RS_ALPHABLENDENABLE, 0);
    let shaders = mode::uses_vertex_shader(b.mode);
    let pixel_shader = match b.mode {
        mode::SHADER_PS11 => b.pixel_shaders[0],
        mode::SHADER_PS20 => b.pixel_shaders[1],
        _ => null_mut(),
    };
    if !pixel_shader.is_null() {
        d3d::set_pixel_shader(dev, pixel_shader);
    }
    if shaders {
        let white = [1.0f32; 4];
        d3d::set_vertex_shader(dev, b.vertex_shader);
        d3d::set_vertex_shader_constant_f(dev, 4, white.as_ptr(), 1);
    }

    let mut world: [f32; 16] = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0];
    for i in 0..b.draws {
        let (x, y, z) = (i % WALL_COLUMNS, (i / WALL_COLUMNS) % WALL_ROWS, i / (WALL_COLUMNS * WALL_ROWS));
        world[12] = (x as f32 - (WALL_COLUMNS / 2) as f32) * WALL_PITCH;
        world[13] = (y as f32 - (WALL_ROWS / 2) as f32) * WALL_PITCH;
        world[14] = WALL_DISTANCE + z as f32 * WALL_SPACING;
        d3d::set_transform(dev, TS_WORLD, world.as_ptr());
        if i % TEXTURE_RUN == 0 {
            d3d::set_texture(dev, 0, b.textures[((i / TEXTURE_RUN) % 2) as usize]);
        }
        match b.mode {
            mode::SHADER | mode::SHADER_PS11 | mode::SHADER_PS20 => {
                // world and projection combined, as the rows of the vertex shader's matrix
                let [xs, ys, zscale, zoffset] = b.proj;
                let (tx, ty, tz) = (world[12], world[13], world[14]);
                let constants: [f32; 16] = [
                    xs, 0.0, 0.0, tx * xs, 0.0, ys, 0.0, ty * ys, 0.0, 0.0, zscale, tz * zscale + zoffset, 0.0, 0.0, 1.0, tz,
                ];
                d3d::set_vertex_shader_constant_f(dev, 0, constants.as_ptr(), 4);
                d3d::draw_primitive(dev, PT_TRIANGLELIST, 0, MESH_TRIANGLES);
            }
            mode::LOCK | mode::LOCK_DISCARD | mode::LOCK_MANAGED => {
                let (buffer, flags) = match b.mode {
                    mode::LOCK_MANAGED => (b.managed_vb, 0),
                    mode::LOCK_DISCARD => (b.dynamic_vb, LOCK_DISCARD),
                    _ => (b.dynamic_vb, 0),
                };
                write_quad(buffer, 0, flags);
                d3d::set_stream_source(dev, 0, buffer, 0, WORLD_STRIDE);
                d3d::draw_primitive(dev, PT_TRIANGLELIST, 0, 2);
            }
            mode::APPEND => {
                // the classic way to fill a dynamic buffer: the next free place, and a new buffer when it is full
                let place = i % DYNAMIC_QUADS;
                write_quad(b.dynamic_vb, place * QUAD_BYTES, if place == 0 { LOCK_DISCARD } else { LOCK_NOOVERWRITE });
                d3d::set_stream_source(dev, 0, b.dynamic_vb, 0, WORLD_STRIDE);
                d3d::draw_primitive(dev, PT_TRIANGLELIST, place * 6, 2);
            }
            mode::STREAM | mode::STREAM_DRAW => {
                if i % TEXTURE_RUN == 0 {
                    // The next texture of the pool, so one comes round again only after a few frames. Magenta on
                    // every frame but the one read back, so an upload at the wrong time shows in the pixel check.
                    b.spare_next = (b.spare_next + 1) % SPARE_TEXTURES;
                    let texture = b.spare[b.spare_next];
                    let dark = DARK[((i / TEXTURE_RUN) % 2) as usize];
                    for level in 0..STREAM_LEVELS {
                        let mut r = LockedRect::EMPTY;
                        d3d::tex_lock_rect(texture, level, &mut r, null_mut(), 0);
                        if !r.bits.is_null() {
                            let (size, cell) = (TEX_SIZE as usize >> level, TEX_CELL >> level);
                            if readback {
                                checkerboard(&r, size, cell, WHITE, dark);
                            } else {
                                checkerboard(&r, size, cell, MAGENTA, MAGENTA);
                            }
                        }
                        d3d::tex_unlock_rect(texture, level);
                    }
                    if b.mode == mode::STREAM_DRAW {
                        d3d::set_texture(dev, 0, texture);
                    }
                }
                d3d::draw_primitive(dev, PT_TRIANGLELIST, 0, MESH_TRIANGLES);
            }
            mode::TOUCH_TEXTURE => {
                let mut r = LockedRect::EMPTY;
                d3d::tex_lock_rect(b.textures[0], 0, &mut r, null_mut(), 0);
                if !r.bits.is_null() {
                    *(r.bits as *mut u32) = WHITE;
                }
                d3d::tex_unlock_rect(b.textures[0], 0);
                d3d::draw_primitive(dev, PT_TRIANGLELIST, 0, MESH_TRIANGLES);
            }
            mode::INDEXED_UP => {
                d3d::draw_indexed_primitive_up(
                    dev, PT_TRIANGLELIST, 0, 4, 2, QUAD_INDICES.as_ptr(), FMT_INDEX16, QUAD_INDEXED.as_ptr(), WORLD_STRIDE,
                );
            }
            _ => {
                d3d::draw_primitive(dev, PT_TRIANGLELIST, 0, MESH_TRIANGLES);
            }
        }
    }
    if shaders {
        d3d::set_vertex_shader(dev, null_mut());
    }
    if !pixel_shader.is_null() {
        d3d::set_pixel_shader(dev, null_mut());
    }
}

/// The "UI": a row of pre-transformed, alpha-blended quads in the vertex layout of the game's UI.
/// `start`: when the world was finished.
unsafe fn draw_ui(b: &mut Bench, dev: P, start: u64) {
    d3d::set_fvf(dev, FVF_UI);
    d3d::set_render_state(dev, RS_LIGHTING, 0);
    d3d::set_render_state(dev, RS_ZENABLE, 0);
    d3d::set_render_state(dev, RS_ALPHABLENDENABLE, 1);
    d3d::set_render_state(dev, RS_SRCBLEND, BLEND_SRCALPHA);
    d3d::set_render_state(dev, RS_DESTBLEND, BLEND_INVSRCALPHA);
    d3d::set_texture(dev, 0, b.textures[0]);
    b.time.ui_state += ticks().wrapping_sub(start);

    for q in 0..UI_QUADS {
        let (x0, y0) = ((UI_LEFT + q * UI_PITCH) as f32, b.height as f32 - UI_ROW_HEIGHT as f32);
        let (x1, y1) = (x0 + UI_QUAD_SIZE as f32, y0 + UI_QUAD_SIZE as f32);
        let c = 0xC0FF_FFFFu32;
        let quad = [
            UiVert { x: x0, y: y0, z: 0.0, rhw: 1.0, c, u: 0.0, v: 0.0 },
            UiVert { x: x1, y: y0, z: 0.0, rhw: 1.0, c, u: 1.0, v: 0.0 },
            UiVert { x: x0, y: y1, z: 0.0, rhw: 1.0, c, u: 0.0, v: 1.0 },
            UiVert { x: x1, y: y1, z: 0.0, rhw: 1.0, c, u: 1.0, v: 1.0 },
        ];
        let before = ticks();
        match b.ui {
            Ui::UserPointer => {
                d3d::draw_primitive_up(dev, PT_TRIANGLESTRIP, 2, quad.as_ptr(), UI_STRIDE);
            }
            Ui::VertexBuffer => {
                let mut dst: *mut u8 = null_mut();
                d3d::vb_lock(b.ui_vb, 0, UI_QUAD_BYTES, &mut dst, LOCK_DISCARD);
                if !dst.is_null() {
                    memcpy(dst, quad.as_ptr() as *const u8, UI_QUAD_BYTES as usize);
                }
                d3d::vb_unlock(b.ui_vb);
                d3d::set_stream_source(dev, 0, b.ui_vb, 0, UI_STRIDE);
                d3d::draw_primitive(dev, PT_TRIANGLESTRIP, 0, 2);
            }
            Ui::None => {}
        }
        let spent = ticks().wrapping_sub(before);
        if q == 0 {
            b.time.ui_first_quad += spent;
        } else {
            b.time.ui_other_quads += spent;
        }
    }
}

/// The frame that is read back is not presented. Returns the result of Present.
unsafe fn frame(b: &mut Bench, dev: P, readback: bool) -> i32 {
    let t0 = ticks();
    d3d::clear(dev, 0, null_mut(), CLEAR_TARGET | CLEAR_ZBUFFER, CLEAR_COLOR, 1.0, 0);
    let t1 = ticks();
    d3d::begin_scene(dev);
    let t2 = ticks();
    draw_world(b, dev, readback);
    let t3 = ticks();
    draw_ui(b, dev, t3);
    let t4 = ticks();
    d3d::end_scene(dev);
    let t5 = ticks();
    let hr = if readback { 0 } else { d3d::present(dev, null_mut(), null_mut(), null_mut(), null_mut()) };
    let t6 = ticks();

    let t = &mut b.time;
    t.clear += t1.wrapping_sub(t0);
    t.begin += t2.wrapping_sub(t1);
    t.world += t3.wrapping_sub(t2);
    t.ui += t4.wrapping_sub(t3);
    t.end += t5.wrapping_sub(t4);
    t.scene += t5.wrapping_sub(t0);
    t.present += t6.wrapping_sub(t5);
    hr
}

// ---- the run ---------------------------------------------------------------------------------------------

/// Returns the timed frames and the milliseconds they took.
unsafe fn run(b: &mut Bench, dev: P, seconds: u32) -> (u32, u32) {
    let start = GetTickCount();
    let mut hr = 0;
    while GetTickCount().wrapping_sub(start) < WARM_UP_MS {
        hr = frame(b, dev, false);
        pump();
    }
    report(b"Present (warm-up)", hr);

    b.time = Timing::ZERO;
    let start = GetTickCount();
    let (mut frames, mut ms) = (0u32, 0u32);
    while ms < seconds.saturating_mul(1000) {
        hr = frame(b, dev, false);
        pump();
        frames += 1;
        ms = GetTickCount().wrapping_sub(start);
    }
    report(b"Present", hr);
    (frames, ms)
}

unsafe fn print_result(b: &Bench, frames: u32, ms: u32) {
    let per_second = |n: u64| if ms > 0 { (n * 1000 / ms as u64) as u32 } else { 0 };
    let ui_draws = if b.ui == Ui::None { 0 } else { UI_QUADS };
    field(b"RESULT frames=", frames);
    field(b" ms=", ms);
    field(b" fps=", per_second(frames as u64));
    field(b" draw-calls/s=", per_second(frames as u64 * (b.draws as u64 + ui_draws as u64)));

    let mut frequency: i64 = 0;
    QueryPerformanceFrequency(&mut frequency);
    let ticks_per_frame_second = frequency as u64 * frames as u64;
    if ticks_per_frame_second > 0 {
        let us = |ticks: u64| (ticks.saturating_mul(1_000_000) / ticks_per_frame_second) as u32;
        let t = &b.time;
        field(b" | per-frame us: scene=", us(t.scene));
        field(b" present=", us(t.present));
        field(b" [clear=", us(t.clear));
        field(b" begin=", us(t.begin));
        field(b" world=", us(t.world));
        field(b" ui=", us(t.ui));
        field(b" end=", us(t.end));
        field(b"] ui: state=", us(t.ui_state));
        field(b" first-quad=", us(t.ui_first_quad));
        field(b" other-", UI_QUADS - 1);
        field(b"=", us(t.ui_other_quads));
    }
    print(b"\n");
}

/// Draws one more frame and reads the back buffer: was anything but the clear colour drawn?
unsafe fn check_pixels(b: &mut Bench, dev: P, o: &Options) {
    frame(b, dev, true);
    let mut target: P = null_mut();
    let mut copy: P = null_mut();
    require(b"GetRenderTarget", d3d::get_render_target(dev, 0, &mut target));
    require(
        b"CreateOffscreenPlainSurface",
        d3d::create_offscreen_plain_surface(dev, o.width, o.height, FMT_X8R8G8B8, POOL_SYSTEMMEM, &mut copy, null_mut()),
    );
    require(b"GetRenderTargetData", d3d::get_render_target_data(dev, target, copy));
    let mut r = LockedRect::EMPTY;
    require(b"Surf.LockRect", d3d::surface_lock_rect(copy, &mut r, null_mut(), LOCK_READONLY));
    require_pointer(b"Surf.LockRect", r.bits);

    let (w, h) = (o.width as usize, o.height as usize);
    let pixel = |x: usize, y: usize| *(r.bits.add(y * r.pitch as usize + x * 4) as *const u32);
    let drawn = |x: usize, y: usize| pixel(x, y) & RGB != CLEAR_COLOR & RGB;
    // the middles of a grid over the picture above the UI, then the middle of each UI quad
    let grid = WORLD_GRID as usize;
    let world_height = h.saturating_sub(UI_AREA_HEIGHT as usize);
    let mut world = 0u32;
    for sy in 0..grid {
        for sx in 0..grid {
            world += drawn(w * (2 * sx + 1) / (2 * grid), world_height * (2 * sy + 1) / (2 * grid)) as u32;
        }
    }
    let ui_middle_y = h.saturating_sub((UI_ROW_HEIGHT - UI_QUAD_SIZE / 2) as usize);
    let mut ui = 0u32;
    for q in 0..UI_QUADS {
        ui += drawn((UI_LEFT + q * UI_PITCH + UI_QUAD_SIZE / 2) as usize, ui_middle_y) as u32;
    }
    field(b"PIXELS world-samples-drawn=", world);
    field(b"/", WORLD_GRID * WORLD_GRID);
    field(b" ui-quads-drawn=", ui);
    field(b"/", UI_QUADS);
    print(b" centre=");
    print_hex(pixel(w / 2, h / 2));
    print(b"\n");
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mainCRTStartup() -> ! {
    let o = options();
    field(b"d3d9bench vp=", o.vertex_processing);
    field(b" ", o.width);
    field(b"x", o.height);
    field(b" draws/frame=", o.draws);
    field(b" tris/draw=", MESH_TRIANGLES);
    field(b" mode=", o.mode);
    print(b"\n");
    if o.width < MIN_WIDTH || o.height < MIN_HEIGHT || o.width > MAX_SIZE || o.height > MAX_SIZE {
        field(b"FAIL size: at least ", MIN_WIDTH);
        field(b" x ", MIN_HEIGHT);
        field(b" for the pixel check, at most ", MAX_SIZE);
        field(b" x ", MAX_SIZE);
        print(b"\n");
        ExitProcess(EXIT_BAD_ARGUMENTS);
    }

    let window = create_window(&o);
    let dev = create_device(&o, window);
    let b = &mut *(&raw mut BENCH);
    b.mode = o.mode;
    b.ui = o.ui;
    b.height = o.height;
    b.draws = o.draws;
    create_resources(b, dev, &o);
    set_fixed_state(b, dev, &o);

    let (frames, ms) = run(b, dev, o.seconds);
    print_result(b, frames, ms);
    check_pixels(b, dev, &o);
    ExitProcess(0)
}
