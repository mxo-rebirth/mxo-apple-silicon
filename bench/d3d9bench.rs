// Minimal Direct3D 9 fixed-function test / draw-call benchmark (no_std, 32-bit Windows).
// usage: d3d9bench.exe <vp 0=hw 1=sw 2=mixed> <width> <height> <draws/frame> <seconds> <tex-fmt 0=A8R8G8B8 1=DXT1>
#![no_std]
#![no_main]
#![allow(non_snake_case, dead_code, static_mut_refs)]

use core::ffi::c_void;
use core::mem::transmute;
use core::ptr::{null, null_mut, read_volatile, write_volatile};

type P = *mut c_void;

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    unsafe { ExitProcess(99) }
}

#[no_mangle]
pub static _fltused: i32 = 0;
#[no_mangle]
pub extern "C" fn __CxxFrameHandler3() {}

// 64-bit division helpers the MSVC target expects from the C runtime (only reached from panic formatting)
fn udivmod(mut n: u64, d: u64) -> (u64, u64) {
    if d == 0 {
        return (0, 0);
    }
    let (mut q, mut r) = (0u64, 0u64);
    let mut i = 0;
    while i < 64 {
        r = (r << 1) | (n >> 63);
        n <<= 1;
        q <<= 1;
        if r >= d {
            r -= d;
            q |= 1;
        }
        i += 1;
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

#[no_mangle]
pub unsafe extern "C" fn memset(d: *mut u8, c: i32, n: usize) -> *mut u8 {
    let mut i = 0;
    while i < n {
        write_volatile(d.add(i), c as u8);
        i += 1;
    }
    d
}
#[no_mangle]
pub unsafe extern "C" fn memcpy(d: *mut u8, s: *const u8, n: usize) -> *mut u8 {
    let mut i = 0;
    while i < n {
        write_volatile(d.add(i), read_volatile(s.add(i)));
        i += 1;
    }
    d
}
#[no_mangle]
pub unsafe extern "C" fn memmove(d: *mut u8, s: *const u8, n: usize) -> *mut u8 {
    if (d as usize) <= (s as usize) {
        return memcpy(d, s, n);
    }
    let mut i = n;
    while i > 0 {
        i -= 1;
        write_volatile(d.add(i), read_volatile(s.add(i)));
    }
    d
}
#[no_mangle]
pub unsafe extern "C" fn memcmp(a: *const u8, b: *const u8, n: usize) -> i32 {
    let mut i = 0;
    while i < n {
        let (x, y) = (read_volatile(a.add(i)), read_volatile(b.add(i)));
        if x != y {
            return x as i32 - y as i32;
        }
        i += 1;
    }
    0
}

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

#[link(name = "kernel32", kind = "raw-dylib", import_name_type = "undecorated")]
extern "system" {
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
extern "system" {
    fn RegisterClassA(wc: *const WNDCLASSA) -> u16;
    fn CreateWindowExA(ex: u32, cls: *const u8, name: *const u8, style: u32, x: i32, y: i32, w: i32, h: i32, parent: P, menu: P, inst: P, param: P) -> P;
    fn DefWindowProcA(h: P, m: u32, w: usize, l: isize) -> isize;
    fn PeekMessageA(msg: *mut MSG, h: P, min: u32, max: u32, remove: u32) -> i32;
    fn TranslateMessage(msg: *const MSG) -> i32;
    fn DispatchMessageA(msg: *const MSG) -> isize;
    fn AdjustWindowRect(r: *mut RECT, style: u32, menu: i32) -> i32;
    fn SetForegroundWindow(h: P) -> i32;
}
#[link(name = "d3d9", kind = "raw-dylib", import_name_type = "undecorated")]
extern "system" {
    fn Direct3DCreate9(sdk: u32) -> P;
}

static mut OUT: P = null_mut();
static mut T_SCENE: u32 = 0;
static mut T_PRESENT: u32 = 0;
static mut T_PART: [u32; 5] = [0; 5];
static mut T_UI: [u32; 3] = [0; 3];
static mut UI_MODE: u32 = 0;
static mut UIVB: P = null_mut();
static mut WMODE: u32 = 0;
static mut DYNVB: P = null_mut();
static mut MANVB: P = null_mut();
static mut SPARE: [P; 2048] = [core::ptr::null_mut(); 2048];
static mut SPAREIDX: usize = 0;
static mut VSH: P = null_mut();
static mut PSH: [P; 2] = [null_mut(); 2];
// ps_1_1: tex t0; mul r0, t0, v0
static PS11_CODE: [u32; 8] = [0xFFFF0101, 0x00000042, 0xB00F0000, 0x00000005, 0x800F0000, 0xB0E40000, 0x90E40000, 0x0000FFFF];
// ps_2_0: dcl t0.xy; dcl_2d s0; texld r0, t0, s0; mov oC0, r0
static PS20_CODE: [u32; 15] = [
    0xFFFF0200, 0x0200001F, 0x80000000, 0xB0030000, 0x0200001F, 0x90000000, 0xA00F0800,
    0x03000042, 0x800F0000, 0xB0E40000, 0xA0E40800, 0x02000001, 0x800F0800, 0x80E40000, 0x0000FFFF,
];
static mut PROJ: [f32; 4] = [0.0; 4];
static QUAD: [f32; 48] = [
    -0.5, -0.5, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, -0.5, 0.5, 0.0, 0.0, 0.0, -1.0, 0.0, 1.0, 0.5, -0.5, 0.0, 0.0, 0.0, -1.0, 1.0, 0.0,
    0.5, -0.5, 0.0, 0.0, 0.0, -1.0, 1.0, 0.0, -0.5, 0.5, 0.0, 0.0, 0.0, -1.0, 0.0, 1.0, 0.5, 0.5, 0.0, 0.0, 0.0, -1.0, 1.0, 1.0,
];
static QUADI: [f32; 32] = [
    -0.5, -0.5, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, -0.5, 0.5, 0.0, 0.0, 0.0, -1.0, 0.0, 1.0,
    0.5, -0.5, 0.0, 0.0, 0.0, -1.0, 1.0, 0.0, 0.5, 0.5, 0.0, 0.0, 0.0, -1.0, 1.0, 1.0,
];
static QIDX: [u16; 6] = [0, 1, 2, 2, 1, 3];
// vs_1_1: dcl_position v0; dcl_normal v1; dcl_texcoord v2; m4x4 oPos, v0, c0; mov oT0, v2; mov oD0, c4
static VS_CODE: [u32; 21] = [
    0xFFFE0101, 0x0000001F, 0x80000000, 0x900F0000, 0x0000001F, 0x80000003, 0x900F0001, 0x0000001F, 0x80000005, 0x900F0002,
    0x00000014, 0xC00F0000, 0x90E40000, 0xA0E40000, 0x00000001, 0xE00F0000, 0x90E40002, 0x00000001, 0xD00F0000, 0xA0E40004, 0x0000FFFF,
];
unsafe fn qpc() -> u32 {
    let mut v: i64 = 0;
    QueryPerformanceCounter(&mut v);
    v as u32
}
const GRID: usize = 8; // mesh = GRID x GRID quads
const MESH_VERTS: usize = GRID * GRID * 6;
static mut MESH: [f32; MESH_VERTS * 8] = [0.0; MESH_VERTS * 8];

unsafe fn ps(s: &[u8]) {
    let mut w = 0u32;
    WriteFile(OUT, s.as_ptr(), s.len() as u32, &mut w, null_mut());
}
unsafe fn pu(mut v: u32) {
    let mut b = [0u8; 10];
    let mut i = 10;
    if v == 0 {
        ps(b"0");
        return;
    }
    while v > 0 {
        i -= 1;
        b[i] = b'0' + (v % 10) as u8;
        v /= 10;
    }
    ps(&b[i..]);
}
unsafe fn ph(v: u32) {
    let h = b"0123456789abcdef";
    let mut b = [0u8; 8];
    let mut i = 0;
    while i < 8 {
        b[i] = h[((v >> (28 - 4 * i)) & 15) as usize];
        i += 1;
    }
    ps(b"0x");
    ps(&b);
}
unsafe fn step(name: &[u8], hr: i32) {
    if hr != 0 {
        ps(b"  FAIL ");
        ps(name);
        ps(b" hr=");
        ph(hr as u32);
        ps(b"\n");
    }
}

macro_rules! com {
    ($obj:expr, $idx:expr, fn($($t:ty),*) -> $r:ty $(, $a:expr)*) => {{
        let o: P = $obj;
        let f: unsafe extern "system" fn(P $(, $t)*) -> $r = transmute(*(*(o as *const *const P)).add($idx));
        f(o $(, $a)*)
    }};
}

unsafe extern "system" fn wndproc(h: P, m: u32, w: usize, l: isize) -> isize {
    DefWindowProcA(h, m, w, l)
}

unsafe fn args(out: &mut [u32; 8]) {
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
    let mut i = 0;
    loop {
        while *p == b' ' {
            p = p.add(1);
        }
        if *p == 0 || i >= 8 {
            break;
        }
        let mut v = 0u32;
        while *p >= b'0' && *p <= b'9' {
            v = v * 10 + (*p - b'0') as u32;
            p = p.add(1);
        }
        while *p != 0 && *p != b' ' {
            p = p.add(1);
        }
        out[i] = v;
        i += 1;
    }
}

unsafe fn pump() {
    let mut m: MSG = core::mem::zeroed();
    while PeekMessageA(&mut m, null_mut(), 0, 0, 1) != 0 {
        TranslateMessage(&m);
        DispatchMessageA(&m);
    }
}

unsafe fn frame(dev: P, vb: P, tex: &[P; 2], w: u32, h: u32, draws: u32, present: bool) -> i32 {
    let t0 = qpc();
    com!(dev, 43, fn(u32, P, u32, u32, f32, u32) -> i32, 0, null_mut(), 3, 0xFF203040, 1.0, 0); // Clear
    let ta = qpc();
    com!(dev, 41, fn() -> i32); // BeginScene
    let tb = qpc();

    // ---- "world": lit fixed-function meshes from a vertex buffer, one draw call each
    com!(dev, 89, fn(u32) -> i32, 0x112); // SetFVF XYZ|NORMAL|TEX1
    com!(dev, 100, fn(u32, P, u32, u32) -> i32, 0, vb, 0, 32); // SetStreamSource
    com!(dev, 57, fn(u32, u32) -> i32, 137, 1); // LIGHTING
    com!(dev, 57, fn(u32, u32) -> i32, 7, 1); // ZENABLE
    com!(dev, 57, fn(u32, u32) -> i32, 27, 0); // ALPHABLENDENABLE
    let mut m: [f32; 16] = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0];
    if WMODE == 8 || WMODE == 9 {
        com!(dev, 107, fn(P) -> i32, PSH[(WMODE - 8) as usize]); // SetPixelShader
    }
    if WMODE == 1 || WMODE == 8 || WMODE == 9 {
        let white = [1.0f32; 4];
        com!(dev, 92, fn(P) -> i32, VSH); // SetVertexShader
        com!(dev, 94, fn(u32, *const f32, u32) -> i32, 4, white.as_ptr(), 1);
    }
    let mut i = 0u32;
    while i < draws {
        let ix = i % 64;
        let iy = (i / 64) % 36;
        let iz = i / (64 * 36);
        m[12] = (ix as f32 - 32.0) * 1.15;
        m[13] = (iy as f32 - 18.0) * 1.15;
        m[14] = 36.0 + iz as f32 * 4.0;
        com!(dev, 44, fn(u32, *const f32) -> i32, 256, m.as_ptr()); // SetTransform(WORLD)
        if i % 8 == 0 {
            com!(dev, 65, fn(u32, P) -> i32, 0, tex[((i / 8) % 2) as usize]); // SetTexture
        }
        match WMODE {
            1 | 8 | 9 => {
                // programmable vertex shader, transform passed as per-draw shader constants
                let c: [f32; 16] = [
                    PROJ[0], 0.0, 0.0, m[12] * PROJ[0], 0.0, PROJ[1], 0.0, m[13] * PROJ[1],
                    0.0, 0.0, PROJ[2], m[14] * PROJ[2] + PROJ[3], 0.0, 0.0, 1.0, m[14],
                ];
                com!(dev, 94, fn(u32, *const f32, u32) -> i32, 0, c.as_ptr(), 4); // SetVertexShaderConstantF
                com!(dev, 81, fn(u32, u32, u32) -> i32, 4, 0, (MESH_VERTS / 3) as u32);
            }
            2 | 4 | 5 => {
                // rewrite a quad through Lock/Unlock before every draw: dynamic (no flags), dynamic DISCARD, managed
                let (b, fl) = if WMODE == 5 { (MANVB, 0u32) } else if WMODE == 4 { (DYNVB, 0x2000) } else { (DYNVB, 0) };
                let mut dst: *mut u8 = null_mut();
                com!(b, 11, fn(u32, u32, *mut *mut u8, u32) -> i32, 0, 192, &mut dst, fl);
                if !dst.is_null() {
                    memcpy(dst, QUAD.as_ptr() as *const u8, 192);
                }
                com!(b, 12, fn() -> i32);
                com!(dev, 100, fn(u32, P, u32, u32) -> i32, 0, b, 0, 32);
                com!(dev, 81, fn(u32, u32, u32) -> i32, 4, 0, 2);
            }
            3 => {
                // classic dynamic-buffer append: NOOVERWRITE, DISCARD when it wraps
                let slot = i % 4096;
                let mut dst: *mut u8 = null_mut();
                com!(DYNVB, 11, fn(u32, u32, *mut *mut u8, u32) -> i32, slot * 192, 192, &mut dst, if slot == 0 { 0x2000 } else { 0x1000 });
                if !dst.is_null() {
                    memcpy(dst, QUAD.as_ptr() as *const u8, 192);
                }
                com!(DYNVB, 12, fn() -> i32);
                com!(dev, 100, fn(u32, P, u32, u32) -> i32, 0, DYNVB, 0, 32);
                com!(dev, 81, fn(u32, u32, u32) -> i32, 4, slot * 6, 2);
            }
            10 | 11 => {
                // texture streaming: every 8 draws, fill a managed texture (3 mip levels) that this frame has
                // not used yet. Mode 11 then draws with it; its contents alternate between frames (the
                // checkerboard of tex[] on the frame that is read back, magenta otherwise), so an upload that
                // runs at the wrong time shows up in the pixel check. Mode 10 only uploads.
                if i % 8 == 0 {
                    let t = ((i / 8) % 2) as usize;
                    // walk through the pool across frames, so a texture comes round again only after a few frames
                    SPAREIDX = (SPAREIDX + 1) % 2048;
                    let sp = SPARE[SPAREIDX];
                    let mut level = 0u32;
                    while level < 3 {
                        let mut lr = [0u32; 2];
                        com!(sp, 19, fn(u32, *mut u32, P, u32) -> i32, level, lr.as_mut_ptr(), null_mut(), 0);
                        if lr[1] != 0 {
                            let size = 64usize >> level;
                            let cell = 8usize >> level;
                            let (pitch, bits) = (lr[0] as usize, lr[1] as *mut u8);
                            let mut y = 0usize;
                            while y < size {
                                let mut x = 0usize;
                                while x < size {
                                    let bright = ((x / cell) + (y / cell)) % 2 == 0;
                                    let c: u32 = if present { 0xFFFF00FF } else if bright { 0xFFFFFFFF } else if t == 0 { 0xFFB0B0B0 } else { 0xFF80C0FF };
                                    *(bits.add(y * pitch + x * 4) as *mut u32) = c;
                                    x += 1;
                                }
                                y += 1;
                            }
                        }
                        com!(sp, 20, fn(u32) -> i32, level);
                        level += 1;
                    }
                    if WMODE == 11 {
                        com!(dev, 65, fn(u32, P) -> i32, 0, sp); // SetTexture
                    }
                }
                com!(dev, 81, fn(u32, u32, u32) -> i32, 4, 0, (MESH_VERTS / 3) as u32);
            }
            6 => {
                // touch a managed texture before every draw
                let mut lr = [0u32; 2];
                com!(tex[0], 19, fn(u32, *mut u32, P, u32) -> i32, 0, lr.as_mut_ptr(), null_mut(), 0);
                if lr[1] != 0 {
                    *(lr[1] as *mut u32) = 0xFFFFFFFF;
                }
                com!(tex[0], 20, fn(u32) -> i32, 0);
                com!(dev, 81, fn(u32, u32, u32) -> i32, 4, 0, (MESH_VERTS / 3) as u32);
            }
            7 => {
                com!(dev, 84, fn(u32, u32, u32, u32, *const u16, u32, *const f32, u32) -> i32, 4, 0, 4, 2, QIDX.as_ptr(), 101, QUADI.as_ptr(), 32); // DrawIndexedPrimitiveUP
            }
            _ => {
                com!(dev, 81, fn(u32, u32, u32) -> i32, 4, 0, (MESH_VERTS / 3) as u32); // DrawPrimitive TRIANGLELIST
            }
        }
        i += 1;
    }
    if WMODE == 1 || WMODE == 8 || WMODE == 9 {
        com!(dev, 92, fn(P) -> i32, null_mut());
    }
    if WMODE == 8 || WMODE == 9 {
        com!(dev, 107, fn(P) -> i32, null_mut());
    }

    let tc = qpc();
    // ---- "UI": pre-transformed, alpha-blended quads (same vertex layout the game's UI uses)
    com!(dev, 89, fn(u32) -> i32, 0x144); // SetFVF XYZRHW|DIFFUSE|TEX1
    com!(dev, 57, fn(u32, u32) -> i32, 137, 0);
    com!(dev, 57, fn(u32, u32) -> i32, 7, 0);
    com!(dev, 57, fn(u32, u32) -> i32, 27, 1);
    com!(dev, 57, fn(u32, u32) -> i32, 19, 5); // SRCBLEND = SRCALPHA
    com!(dev, 57, fn(u32, u32) -> i32, 20, 6); // DESTBLEND = INVSRCALPHA
    com!(dev, 65, fn(u32, P) -> i32, 0, tex[0]);
    let ts = qpc();
    T_UI[0] = T_UI[0].wrapping_add(ts.wrapping_sub(tc));
    let mut q = 0u32;
    while q < 24 {
        let x0 = 10.0 + q as f32 * 34.0;
        let y0 = h as f32 - 44.0;
        let (x1, y1) = (x0 + 28.0, y0 + 28.0);
        let c = 0xC0FFFFFFu32;
        let v = [
            UiVert { x: x0, y: y0, z: 0.0, rhw: 1.0, c, u: 0.0, v: 0.0 },
            UiVert { x: x1, y: y0, z: 0.0, rhw: 1.0, c, u: 1.0, v: 0.0 },
            UiVert { x: x0, y: y1, z: 0.0, rhw: 1.0, c, u: 0.0, v: 1.0 },
            UiVert { x: x1, y: y1, z: 0.0, rhw: 1.0, c, u: 1.0, v: 1.0 },
        ];
        let tq = qpc();
        if UI_MODE == 1 {
            // same quad through a dynamic vertex buffer: Lock(DISCARD) / copy / Unlock / DrawPrimitive
            let mut dst: *mut u8 = null_mut();
            com!(UIVB, 11, fn(u32, u32, *mut *mut u8, u32) -> i32, 0, 112, &mut dst, 0x2000);
            memcpy(dst, v.as_ptr() as *const u8, 112);
            com!(UIVB, 12, fn() -> i32);
            com!(dev, 100, fn(u32, P, u32, u32) -> i32, 0, UIVB, 0, 28);
            com!(dev, 81, fn(u32, u32, u32) -> i32, 5, 0, 2);
        } else if UI_MODE == 0 {
            com!(dev, 83, fn(u32, u32, *const UiVert, u32) -> i32, 5, 2, v.as_ptr(), 28); // DrawPrimitiveUP TRIANGLESTRIP
        }
        let idx = if q == 0 { 1 } else { 2 };
        T_UI[idx] = T_UI[idx].wrapping_add(qpc().wrapping_sub(tq));
        q += 1;
    }
    let _ = w;
    let td = qpc();
    com!(dev, 42, fn() -> i32); // EndScene
    let t1 = qpc();
    T_PART[0] = T_PART[0].wrapping_add(ta.wrapping_sub(t0));
    T_PART[1] = T_PART[1].wrapping_add(tb.wrapping_sub(ta));
    T_PART[2] = T_PART[2].wrapping_add(tc.wrapping_sub(tb));
    T_PART[3] = T_PART[3].wrapping_add(td.wrapping_sub(tc));
    T_PART[4] = T_PART[4].wrapping_add(t1.wrapping_sub(td));
    let hr = if present {
        com!(dev, 17, fn(P, P, P, P) -> i32, null_mut(), null_mut(), null_mut(), null_mut())
    } else {
        0
    };
    let t2 = qpc();
    T_SCENE = T_SCENE.wrapping_add(t1.wrapping_sub(t0));
    T_PRESENT = T_PRESENT.wrapping_add(t2.wrapping_sub(t1));
    hr
}

#[no_mangle]
pub unsafe extern "C" fn mainCRTStartup() -> ! {
    OUT = GetStdHandle(0xFFFF_FFF5);
    let mut a = [0u32, 1280, 720, 2000, 4, 0, 0, 0];
    args(&mut a);
    let (vp, w, h, draws, secs, texfmt, flags) = (a[0], a[1], a[2], a[3], a[4], a[5], a[6]);
    UI_MODE = (flags >> 1) & 3;
    WMODE = a[7];
    ps(b"d3d9bench vp=");
    pu(vp);
    ps(b" ");
    pu(w);
    ps(b"x");
    pu(h);
    ps(b" draws/frame=");
    pu(draws);
    ps(b" tris/draw=");
    pu((MESH_VERTS / 3) as u32);
    ps(b"\n");

    let inst = GetModuleHandleA(null());
    let cls = b"d3d9bench\0";
    let wc = WNDCLASSA { style: 0, wndproc, cls_extra: 0, wnd_extra: 0, inst, icon: null_mut(), cursor: null_mut(), bg: null_mut(), menu: null(), name: cls.as_ptr() };
    RegisterClassA(&wc);
    let style = if flags & 8 != 0 { 0x90000000u32 } else { 0x10CA0000u32 }; // WS_POPUP|WS_VISIBLE for fullscreen
    let mut r = RECT { l: 0, t: 0, r: w as i32, b: h as i32 };
    AdjustWindowRect(&mut r, style, 0);
    let hwnd = CreateWindowExA(if flags & 1 != 0 { 8 } else { 0 }, cls.as_ptr(), b"d3d9 backend test\0".as_ptr(), style, 60, 80, r.r - r.l, r.b - r.t, null_mut(), null_mut(), inst, null_mut());
    if hwnd.is_null() {
        ps(b"FAIL CreateWindow\n");
        ExitProcess(2);
    }
    if flags & 1 != 0 {
        SetForegroundWindow(hwnd);
    }
    pump();

    let d3d = Direct3DCreate9(32);
    if d3d.is_null() {
        ps(b"FAIL Direct3DCreate9\n");
        ExitProcess(3);
    }
    let mut pp = [0u32; 14];
    pp[0] = w;
    pp[1] = h;
    pp[2] = 22; // X8R8G8B8
    pp[3] = 1;
    pp[6] = 1; // SWAPEFFECT_DISCARD
    pp[7] = hwnd as u32;
    pp[8] = if flags & 8 != 0 { 0 } else { 1 }; // windowed
    pp[9] = 1; // auto depth stencil
    pp[10] = 75; // D24S8
    pp[13] = 0x8000_0000; // PRESENT_INTERVAL_IMMEDIATE
    let flags = match vp {
        0 => 0x40,
        1 => 0x20,
        _ => 0x80,
    };
    let mut dev: P = null_mut();
    let hr = com!(d3d, 16, fn(u32, u32, P, u32, *mut u32, *mut P) -> i32, 0, 1, hwnd, flags, pp.as_mut_ptr(), &mut dev);
    if hr != 0 || dev.is_null() {
        ps(b"FAIL CreateDevice hr=");
        ph(hr as u32);
        ps(b"\n");
        ExitProcess(4);
    }

    // two checkerboard textures
    let mut tex: [P; 2] = [null_mut(); 2];
    let mut t = 0usize;
    while t < 2 {
        let fmt = if texfmt == 1 { 0x31545844 } else { 21 };
        step(b"CreateTexture", com!(dev, 23, fn(u32, u32, u32, u32, u32, u32, *mut P, P) -> i32, 64, 64, 1, 0, fmt, 1, &mut tex[t], null_mut()));
        let mut lr = [0u32; 2];
        step(b"Tex.LockRect", com!(tex[t], 19, fn(u32, *mut u32, P, u32) -> i32, 0, lr.as_mut_ptr(), null_mut(), 0));
        let pitch = lr[0] as usize;
        let bits = lr[1] as *mut u8;
        if texfmt == 1 {
            // DXT1: 16x16 blocks of 8 bytes: two RGB565 colours + 4x4 2-bit indices
            let mut b = 0usize;
            while b < 256 {
                let bright = ((b % 16) / 2 + (b / 16) / 2) % 2 == 0;
                let c0: u16 = if bright { 0xFFFF } else if t == 0 { 0xB596 } else { 0x861F };
                let blk = bits.add((b / 16) * pitch + (b % 16) * 8);
                *(blk as *mut u16) = c0;
                *(blk.add(2) as *mut u16) = c0;
                *(blk.add(4) as *mut u32) = 0;
                b += 1;
            }
        } else {
            let mut y = 0usize;
            while y < 64 {
                let mut x = 0usize;
                while x < 64 {
                    let bright = ((x / 8) + (y / 8)) % 2 == 0;
                    let c: u32 = if bright { 0xFFFFFFFF } else if t == 0 { 0xFFB0B0B0 } else { 0xFF80C0FF };
                    *(bits.add(y * pitch + x * 4) as *mut u32) = c;
                    x += 1;
                }
                y += 1;
            }
        }
        step(b"Tex.UnlockRect", com!(tex[t], 20, fn(u32) -> i32, 0));
        t += 1;
    }

    // mesh: GRID x GRID quads in the XY plane, 1x1 units, facing the camera
    let mut n = 0usize;
    let mut gy = 0usize;
    while gy < GRID {
        let mut gx = 0usize;
        while gx < GRID {
            let s = 1.0 / GRID as f32;
            let (x0, y0) = (gx as f32 * s - 0.5, gy as f32 * s - 0.5);
            let (x1, y1) = (x0 + s, y0 + s);
            let c = [(x0, y0), (x0, y1), (x1, y0), (x1, y0), (x0, y1), (x1, y1)];
            let mut k = 0;
            while k < 6 {
                let o = n * 8;
                MESH[o] = c[k].0;
                MESH[o + 1] = c[k].1;
                MESH[o + 2] = 0.0;
                MESH[o + 3] = 0.0;
                MESH[o + 4] = 0.0;
                MESH[o + 5] = -1.0;
                MESH[o + 6] = c[k].0 + 0.5;
                MESH[o + 7] = c[k].1 + 0.5;
                n += 1;
                k += 1;
            }
            gx += 1;
        }
        gy += 1;
    }
    let bytes = (MESH_VERTS * 32) as u32;
    let mut vb: P = null_mut();
    step(b"CreateVertexBuffer", com!(dev, 26, fn(u32, u32, u32, u32, *mut P, P) -> i32, bytes, 8, 0x112, 1, &mut vb, null_mut()));
    let mut dst: *mut u8 = null_mut();
    step(b"VB.Lock", com!(vb, 11, fn(u32, u32, *mut *mut u8, u32) -> i32, 0, bytes, &mut dst, 0));
    memcpy(dst, MESH.as_ptr() as *const u8, bytes as usize);
    step(b"VB.Unlock", com!(vb, 12, fn() -> i32));

    step(b"CreateVertexBuffer(dyn)", com!(dev, 26, fn(u32, u32, u32, u32, *mut P, P) -> i32, 192 * 4096, 0x208, 0x112, 0, &mut DYNVB, null_mut()));
    if WMODE == 10 || WMODE == 11 {
        let mut k = 0usize;
        while k < 2048 {
            com!(dev, 23, fn(u32, u32, u32, u32, u32, u32, *mut P, P) -> i32, 64, 64, 3, 0, 21, 1, &mut SPARE[k], null_mut());
            k += 1;
        }
    }
    step(b"CreateVertexBuffer(managed)", com!(dev, 26, fn(u32, u32, u32, u32, *mut P, P) -> i32, 192 * 16, 8, 0x112, 1, &mut MANVB, null_mut()));
    step(b"CreateVertexShader", com!(dev, 91, fn(*const u32, *mut P) -> i32, VS_CODE.as_ptr(), &mut VSH));
    step(b"CreatePixelShader(ps_1_1)", com!(dev, 106, fn(*const u32, *mut P) -> i32, PS11_CODE.as_ptr(), &mut PSH[0]));
    step(b"CreatePixelShader(ps_2_0)", com!(dev, 106, fn(*const u32, *mut P) -> i32, PS20_CODE.as_ptr(), &mut PSH[1]));
    step(b"CreateVertexBuffer(ui)", com!(dev, 26, fn(u32, u32, u32, u32, *mut P, P) -> i32, 112, 0x208, 0x144, 0, &mut UIVB, null_mut()));
    // camera, light, material, sampler/stage setup
    let ys = 1.7320508f32;
    let xs = ys * h as f32 / w as f32;
    let (zn, zf) = (1.0f32, 2000.0f32);
    PROJ = [xs, ys, zf / (zf - zn), -zn * zf / (zf - zn)];
    let proj: [f32; 16] = [xs, 0.0, 0.0, 0.0, 0.0, ys, 0.0, 0.0, 0.0, 0.0, zf / (zf - zn), 1.0, 0.0, 0.0, -zn * zf / (zf - zn), 0.0];
    let ident: [f32; 16] = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0];
    com!(dev, 44, fn(u32, *const f32) -> i32, 3, proj.as_ptr());
    com!(dev, 44, fn(u32, *const f32) -> i32, 2, ident.as_ptr());
    let mut light = [0f32; 26];
    light[0] = f32::from_bits(3); // D3DLIGHT_DIRECTIONAL
    light[1] = 1.0;
    light[2] = 1.0;
    light[3] = 1.0;
    light[4] = 1.0;
    light[16] = 0.3;
    light[17] = -0.3;
    light[18] = 1.0;
    step(b"SetLight", com!(dev, 51, fn(u32, *const f32) -> i32, 0, light.as_ptr()));
    com!(dev, 53, fn(u32, i32) -> i32, 0, 1);
    let mut mat = [0f32; 17];
    let mut k = 0;
    while k < 8 {
        mat[k] = 1.0;
        k += 1;
    }
    com!(dev, 49, fn(*const f32) -> i32, mat.as_ptr());
    com!(dev, 57, fn(u32, u32) -> i32, 139, 0x00404040); // AMBIENT
    com!(dev, 57, fn(u32, u32) -> i32, 22, 1); // CULLMODE none
    com!(dev, 69, fn(u32, u32, u32) -> i32, 0, 5, 2); // MAGFILTER linear
    com!(dev, 69, fn(u32, u32, u32) -> i32, 0, 6, 2); // MINFILTER linear
    com!(dev, 67, fn(u32, u32, u32) -> i32, 0, 1, 4); // COLOROP modulate
    com!(dev, 67, fn(u32, u32, u32) -> i32, 0, 2, 2); // COLORARG1 texture
    com!(dev, 67, fn(u32, u32, u32) -> i32, 0, 3, 0); // COLORARG2 diffuse
    com!(dev, 67, fn(u32, u32, u32) -> i32, 0, 4, 4); // ALPHAOP modulate
    com!(dev, 67, fn(u32, u32, u32) -> i32, 0, 5, 2);
    com!(dev, 67, fn(u32, u32, u32) -> i32, 0, 6, 0);

    // warm-up, then timed run
    let t0 = GetTickCount();
    let mut phr = 0;
    while GetTickCount().wrapping_sub(t0) < 1500 {
        phr = frame(dev, vb, &tex, w, h, draws, true);
        pump();
    }
    step(b"Present (warm-up)", phr);
    let t1 = GetTickCount();
    T_SCENE = 0;
    T_PRESENT = 0;
    T_PART = [0; 5];
    T_UI = [0; 3];
    let mut frames = 0u32;
    let mut el = 0u32;
    while el < secs * 1000 {
        phr = frame(dev, vb, &tex, w, h, draws, true);
        pump();
        frames += 1;
        el = GetTickCount().wrapping_sub(t1);
    }
    step(b"Present", phr);
    ps(b"RESULT frames=");
    pu(frames);
    ps(b" ms=");
    pu(el);
    ps(b" fps=");
    pu(if el > 0 { frames * 1000 / el } else { 0 });
    ps(b" draw-calls/s=");
    pu(if el > 0 { (frames * 1000 / el) * (draws + 24) } else { 0 });
    let mut f: i64 = 0;
    QueryPerformanceFrequency(&mut f);
    let per_us = (f as u32) / 1_000_000;
    if frames > 0 && per_us > 0 {
        ps(b" | per-frame us: scene=");
        pu(T_SCENE / frames / per_us);
        ps(b" present=");
        pu(T_PRESENT / frames / per_us);
        ps(b" [clear=");
        pu(T_PART[0] / frames / per_us);
        ps(b" begin=");
        pu(T_PART[1] / frames / per_us);
        ps(b" world=");
        pu(T_PART[2] / frames / per_us);
        ps(b" ui=");
        pu(T_PART[3] / frames / per_us);
        ps(b" end=");
        pu(T_PART[4] / frames / per_us);
        ps(b"] ui: state=");
        pu(T_UI[0] / frames / per_us);
        ps(b" first-quad=");
        pu(T_UI[1] / frames / per_us);
        ps(b" other-23=");
        pu(T_UI[2] / frames / per_us);
    }
    ps(b"\n");

    // read the back buffer: did anything other than the clear colour get drawn?
    frame(dev, vb, &tex, w, h, draws, false);
    let mut rt: P = null_mut();
    let mut surf: P = null_mut();
    step(b"GetRenderTarget", com!(dev, 38, fn(u32, *mut P) -> i32, 0, &mut rt));
    step(b"CreateOffscreenPlainSurface", com!(dev, 36, fn(u32, u32, u32, u32, *mut P, P) -> i32, w, h, 22, 2, &mut surf, null_mut()));
    let hr = com!(dev, 32, fn(P, P) -> i32, rt, surf);
    step(b"GetRenderTargetData", hr);
    if hr == 0 {
        let mut lr = [0u32; 2];
        step(b"Surf.LockRect", com!(surf, 13, fn(*mut u32, P, u32) -> i32, lr.as_mut_ptr(), null_mut(), 0x10));
        let (pitch, bits) = (lr[0] as usize, lr[1] as *const u8);
        let mut world = 0u32;
        let mut ui = 0u32;
        let mut sy = 0u32;
        while sy < 16 {
            let mut sx = 0u32;
            while sx < 16 {
                let (x, y) = ((w * (2 * sx + 1) / 32) as usize, ((h - 60) * (2 * sy + 1) / 32) as usize);
                if *(bits.add(y * pitch + x * 4) as *const u32) & 0xFFFFFF != 0x203040 {
                    world += 1;
                }
                sx += 1;
            }
            sy += 1;
        }
        let mut q = 0usize;
        while q < 24 {
            let (x, y) = (10 + q * 34 + 14, h as usize - 30);
            if *(bits.add(y * pitch + x * 4) as *const u32) & 0xFFFFFF != 0x203040 {
                ui += 1;
            }
            q += 1;
        }
        let centre = *(bits.add((h as usize / 2) * pitch + (w as usize / 2) * 4) as *const u32);
        ps(b"PIXELS world-samples-drawn=");
        pu(world);
        ps(b"/256 ui-quads-drawn=");
        pu(ui);
        ps(b"/24 centre=");
        ph(centre);
        ps(b"\n");
    }
    ExitProcess(0)
}
