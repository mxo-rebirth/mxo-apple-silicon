# Synthetic x87 routines covering every instruction form the translator handles.
# void __cdecl tN(const In* in, Out* out)
#   In : float f[16] @0, int32 i[4] @64, double d[4] @80, int16 w[2] @112, int64 q @116
#   Out: float o[16] @0, double od[4] @64, int32 oi[4] @96, int16 ow[2] @112, int64 oq @116
.intel_syntax noprefix
.text
.globl _synth_begin
_synth_begin:

.globl _t1
_t1:
  push ebp
  mov ebp, esp
  mov eax, [ebp+8]
  mov edx, [ebp+12]
  fld dword ptr [eax]
  fadd dword ptr [eax+4]
  fmul dword ptr [eax+8]
  fsub dword ptr [eax+12]
  fdiv dword ptr [eax+16]
  fsubr dword ptr [eax+20]
  fdivr dword ptr [eax+24]
  fst dword ptr [edx]
  fmul dword ptr [eax+28]
  fstp dword ptr [edx+4]
  fld dword ptr [eax+32]
  fmul dword ptr [eax+36]
  fmul dword ptr [eax+40]
  fdiv dword ptr [eax+44]
  fdiv dword ptr [eax+48]
  fstp dword ptr [edx+8]
  fld dword ptr [eax+52]
  fsub dword ptr [eax+56]
  fmul dword ptr [eax+60]
  fst qword ptr [edx+64]
  fstp dword ptr [edx+12]
  pop ebp
  ret
_t1_end:

.p2align 4
.globl _t2
_t2:
  push ebp
  mov ebp, esp
  mov eax, [ebp+8]
  mov edx, [ebp+12]
  fld qword ptr [eax+80]
  fadd qword ptr [eax+88]
  fmul qword ptr [eax+96]
  fsub qword ptr [eax+104]
  fst qword ptr [edx+64]
  fdivr qword ptr [eax+80]
  fsubr qword ptr [eax+88]
  fdiv qword ptr [eax+96]
  fstp qword ptr [edx+72]
  fld dword ptr [eax]
  fmul qword ptr [eax+80]
  fstp dword ptr [edx]
  fld qword ptr [eax+88]
  fstp dword ptr [edx+4]
  fld dword ptr [eax+4]
  fstp qword ptr [edx+80]
  pop ebp
  ret
_t2_end:

.p2align 4
.globl _t3
_t3:
  push ebp
  mov ebp, esp
  mov eax, [ebp+8]
  mov edx, [ebp+12]
  fld dword ptr [eax]
  fld dword ptr [eax+4]
  fld dword ptr [eax+8]
  fld dword ptr [eax+12]
  fadd st, st(1)
  fmul st, st(2)
  fsub st, st(3)
  fsubr st, st(1)
  fdiv st, st(2)
  fdivr st, st(3)
  fxch st(2)
  fadd st(1), st
  fmul st(2), st
  fsub st(3), st
  fsubr st(1), st
  fdiv st(2), st
  fdivr st(3), st
  fld st(2)
  fst st(4)
  fadd st, st(0)
  fstp st(1)
  fld st(3)
  fld st(1)
  fsubp st(1), st
  fst dword ptr [edx+16]
  fsubrp st(2), st
  fst dword ptr [edx+20]
  fld dword ptr [eax+16]
  fld dword ptr [eax+20]
  fdivp st(1), st
  fst dword ptr [edx+24]
  fld dword ptr [eax+24]
  fdivrp st(1), st
  fst dword ptr [edx+28]
  faddp st(1), st
  fmulp st(1), st
  fxch st(1)
  fstp dword ptr [edx]
  fstp dword ptr [edx+4]
  fstp dword ptr [edx+8]
  pop ebp
  ret
_t3_end:

.p2align 4
.globl _t4
_t4:
  push ebp
  mov ebp, esp
  mov eax, [ebp+8]
  mov edx, [ebp+12]
  fild dword ptr [eax+64]
  fiadd dword ptr [eax+68]
  fimul dword ptr [eax+72]
  fisub dword ptr [eax+76]
  fstp dword ptr [edx]
  fild word ptr [eax+112]
  fild qword ptr [eax+116]
  faddp st(1), st
  fstp qword ptr [edx+64]
  fld dword ptr [eax]
  fistp dword ptr [edx+96]
  fld dword ptr [eax+4]
  fist dword ptr [edx+100]
  fistp word ptr [edx+112]
  fld dword ptr [eax+8]
  fistp qword ptr [edx+116]
  fild dword ptr [eax+64]
  fidiv dword ptr [eax+68]
  fidivr dword ptr [eax+72]
  fisubr dword ptr [eax+76]
  fstp dword ptr [edx+4]
  fild dword ptr [eax+72]
  fstp dword ptr [edx+8]
  fld dword ptr [eax+12]
  fmul dword ptr [eax+16]
  fistp dword ptr [edx+104]
  pop ebp
  ret
_t4_end:

.p2align 4
.globl _t5
_t5:
  push ebp
  mov ebp, esp
  mov eax, [ebp+8]
  mov edx, [ebp+12]
  fld dword ptr [eax]
  fabs
  fsqrt
  fchs
  fstp dword ptr [edx]
  fld1
  fldz
  fldpi
  fmul dword ptr [eax+4]
  fstp dword ptr [edx+4]
  fsub dword ptr [eax+8]
  fstp dword ptr [edx+8]
  fdiv dword ptr [eax+12]
  fstp dword ptr [edx+12]
  fld dword ptr [eax+16]
  fsqrt
  fstp dword ptr [edx+16]
  fld dword ptr [eax+20]
  fmul dword ptr [eax+24]
  fabs
  fsqrt
  fmul dword ptr [eax+28]
  fchs
  fstp qword ptr [edx+64]
  pop ebp
  ret
_t5_end:

.p2align 4
.globl _t6
_t6:
  push ebp
  mov ebp, esp
  sub esp, 8
  push esi
  mov esi, [ebp+8]
  xor ecx, ecx
  fld dword ptr [esi]
  fcomp dword ptr [esi+4]
  fnstsw ax
  test ah, 0x41
  jnz 1f
  or ecx, 1
1:
  fld dword ptr [esi+8]
  fld dword ptr [esi+12]
  fcompp
  fnstsw ax
  test ah, 5
  jp 2f
  or ecx, 2
2:
  fld dword ptr [esi+16]
  ftst
  fnstsw ax
  sahf
  jbe 3f
  or ecx, 4
3:
  fstp st(0)
  fld dword ptr [esi+20]
  fld dword ptr [esi+24]
  fcom st(1)
  fnstsw ax
  test ah, 0x44
  jp 4f
  or ecx, 8
4:
  fucompp
  fnstsw ax
  and ah, 0x45
  cmp ah, 0x40
  jne 5f
  or ecx, 16
5:
  fld dword ptr [esi+28]
  cmp dword ptr [esi+64], 1000
  fcomp qword ptr [esi+80]
  fnstsw ax
  mov [ebp-4], eax
  jl 6f
  or ecx, 32
6:
  mov eax, [ebp-4]
  test ah, 1
  jz 7f
  or ecx, 64
7:
  fld dword ptr [esi+32]
  fld dword ptr [esi+36]
  fcomp st(1)
  fnstsw ax
  test ah, 0x41
  jz 8f
  or ecx, 128
8:
  fcom dword ptr [esi+40]
  fnstsw ax
  fstp st(0)
  test ah, 0x40
  jz 9f
  or ecx, 256
9:
  fld dword ptr [esi+44]
  fcomp qword ptr [esi+88]
  fnstsw ax
  test ah, 1
  jnz 10f
  or ecx, 512
10:
  mov edx, [ebp+12]
  mov [edx+96], ecx
  pop esi
  mov esp, ebp
  pop ebp
  ret
_t6_end:

.p2align 4
.globl _t7
_t7:
  push ebp
  mov ebp, esp
  mov eax, [ebp+8]
  mov edx, [ebp+12]
  fld dword ptr [eax]
  fsin
  fstp dword ptr [edx]
  fld dword ptr [eax+4]
  fcos
  fstp dword ptr [edx+4]
  fld dword ptr [eax+8]
  fld dword ptr [eax+12]
  fpatan
  fstp dword ptr [edx+8]
  fld dword ptr [eax+16]
  frndint
  fstp dword ptr [edx+12]
  fld dword ptr [eax+20]
  fptan
  fstp dword ptr [edx+20]
  fstp dword ptr [edx+16]
  fld dword ptr [eax+24]
  fld dword ptr [eax+28]
  fabs
  fyl2x
  fstp dword ptr [edx+24]
  fld dword ptr [eax+32]
  fsincos
  fstp dword ptr [edx+28]
  fstp dword ptr [edx+32]
  pop ebp
  ret
_t7_end:

.p2align 4
.globl _t8h
_t8h:
  mov eax, [esp+4]
  fld dword ptr [eax]
  fmul dword ptr [eax+4]
  ret
_t8h_end:

.p2align 4
.globl _t8
_t8:
  push ebp
  mov ebp, esp
  mov eax, [ebp+8]
  push eax
  call _t8h
  add esp, 4
  mov edx, [ebp+12]
  fstp dword ptr [edx]
  mov eax, [ebp+8]
  add eax, 8
  push eax
  call _t8h
  add esp, 4
  mov eax, [ebp+8]
  fadd dword ptr [eax+16]
  pop ebp
  ret
_t8_end:

.p2align 4
.globl _t9
_t9:
  push ebp
  mov ebp, esp
  push esi
  push edi
  mov esi, [ebp+8]
  mov edi, [ebp+12]
  xor ecx, ecx
  xor edx, edx
  fldz
1:
  fld dword ptr [esi+ecx*4]
  fmul dword ptr [esi+ecx*4+4]
  faddp st(1), st
  fld st(0)
  fabs
  test ecx, 1
  fcomp dword ptr [esi+60]
  fnstsw ax
  jz 2f
  inc edx
2:
  test ah, 0x41
  jz 3f
  inc ecx
  cmp ecx, 12
  jb 1b
  fstp dword ptr [edi]
  mov dword ptr [edi+96], ecx
  mov dword ptr [edi+100], edx
  jmp 4f
3:
  fchs
  fstp dword ptr [edi]
  mov dword ptr [edi+96], -1
  mov dword ptr [edi+100], edx
4:
  pop edi
  pop esi
  pop ebp
  ret
_t9_end:

.p2align 4
.globl _t10
_t10:
  push ebp
  mov ebp, esp
  sub esp, 16
  push esi
  push edi
  mov esi, [ebp+8]
  mov edi, [ebp+12]
  xor ecx, ecx
  fld dword ptr [esi]
  fmul dword ptr [esi+4]
  fstp dword ptr [ebp-4]
  fld dword ptr [ebp-4]
  fcomp qword ptr [esi+80]
  fld dword ptr [ebp-4]
  fadd dword ptr [esi+8]
  fnstsw ax
  movzx edx, ah
  and edx, 0xfd
  mov [edi+104], edx
  test ah, 1
  jne 1f
  fstp dword ptr [edi]
  jmp 2f
1:
  fstp dword ptr [edi+4]
  or ecx, 1
2:
  fld dword ptr [esi+12]
  fcomp dword ptr [esi+16]
  fld dword ptr [esi+20]
  fmul dword ptr [esi+24]
  fnstsw ax
  test ah, 5
  jp 3f
  fchs
  or ecx, 2
3:
  fstp dword ptr [edi+8]
  fld dword ptr [esi+28]
  fld dword ptr [esi+32]
  fcompp
  fld1
  fnstsw ax
  fstp st(0)
  test ah, 0x44
  jp 4f
  or ecx, 4
4:
  fld dword ptr [esi+36]
  ftst
  fld st(0)
  fmul st, st(1)
  fxch st(1)
  fnstsw ax
  movzx edx, ah
  and edx, 0xfd
  mov [edi+108], edx
  sahf
  ja 5f
  or ecx, 8
5:
  fstp dword ptr [edi+12]
  fstp dword ptr [edi+16]
  fld dword ptr [esi+40]
  fld dword ptr [esi+44]
  fcom st(1)
  fnstsw ax
  movzx edx, ah
  mov [edi+112], dx
  fstp st(0)
  fstp st(0)
  mov [edi+96], ecx
  pop edi
  pop esi
  mov esp, ebp
  pop ebp
  ret
_t10_end:

# t11: every "test ah, M / jcc" a compare is followed by, with ax dead afterwards, so the translator turns
# each into a direct branch on the compare (single floats, doubles and register operands, NaN included)
.globl _t11
_t11:
  push ebp
  mov ebp, esp
  push esi
  push edi
  mov esi, [ebp+8]
  mov edi, [ebp+12]
  xor ecx, ecx
  xor edx, edx
  fld dword ptr [esi+0]
  fcomp dword ptr [esi+12]
  fnstsw ax
  test ah, 0x01
  jz 1f
  or ecx, 0x1
1:
  xor eax, eax
  fld dword ptr [esi+20]
  fcomp qword ptr [esi+88]
  fnstsw ax
  test ah, 0x01
  jnz 1f
  or ecx, 0x2
1:
  xor eax, eax
  fld dword ptr [esi+4]
  fld dword ptr [esi+40]
  fcompp
  fnstsw ax
  test ah, 0x01
  jp 1f
  or ecx, 0x4
1:
  xor eax, eax
  fld dword ptr [esi+60]
  fcomp dword ptr [esi+32]
  fnstsw ax
  test ah, 0x01
  jnp 1f
  or ecx, 0x8
1:
  xor eax, eax
  fld dword ptr [esi+16]
  fcomp qword ptr [esi+80]
  fnstsw ax
  test ah, 0x04
  jz 1f
  or ecx, 0x10
1:
  xor eax, eax
  fld dword ptr [esi+24]
  fld dword ptr [esi+36]
  fcompp
  fnstsw ax
  test ah, 0x04
  jnz 1f
  or ecx, 0x20
1:
  xor eax, eax
  fld dword ptr [esi+56]
  fcomp dword ptr [esi+52]
  fnstsw ax
  test ah, 0x04
  jp 1f
  or ecx, 0x40
1:
  xor eax, eax
  fld dword ptr [esi+12]
  fcomp qword ptr [esi+104]
  fnstsw ax
  test ah, 0x04
  jnp 1f
  or ecx, 0x80
1:
  xor eax, eax
  fld dword ptr [esi+44]
  fld dword ptr [esi+32]
  fcompp
  fnstsw ax
  test ah, 0x05
  jz 1f
  or ecx, 0x100
1:
  xor eax, eax
  fld dword ptr [esi+52]
  fcomp dword ptr [esi+8]
  fnstsw ax
  test ah, 0x05
  jnz 1f
  or ecx, 0x200
1:
  xor eax, eax
  fld dword ptr [esi+8]
  fcomp qword ptr [esi+96]
  fnstsw ax
  test ah, 0x05
  jp 1f
  or ecx, 0x400
1:
  xor eax, eax
  fld dword ptr [esi+0]
  fld dword ptr [esi+28]
  fcompp
  fnstsw ax
  test ah, 0x05
  jnp 1f
  or ecx, 0x800
1:
  xor eax, eax
  fld dword ptr [esi+48]
  fcomp dword ptr [esi+28]
  fnstsw ax
  test ah, 0x40
  jz 1f
  or ecx, 0x1000
1:
  xor eax, eax
  fld dword ptr [esi+4]
  fcomp qword ptr [esi+88]
  fnstsw ax
  test ah, 0x40
  jnz 1f
  or ecx, 0x2000
1:
  xor eax, eax
  fld dword ptr [esi+20]
  fld dword ptr [esi+24]
  fcompp
  fnstsw ax
  test ah, 0x40
  jp 1f
  or ecx, 0x4000
1:
  xor eax, eax
  fld dword ptr [esi+44]
  fcomp dword ptr [esi+48]
  fnstsw ax
  test ah, 0x40
  jnp 1f
  or ecx, 0x8000
1:
  xor eax, eax
  fld dword ptr [esi+0]
  fcomp qword ptr [esi+80]
  fnstsw ax
  test ah, 0x41
  jz 1f
  or ecx, 0x10000
1:
  xor eax, eax
  fld dword ptr [esi+40]
  fld dword ptr [esi+20]
  fcompp
  fnstsw ax
  test ah, 0x41
  jnz 1f
  or ecx, 0x20000
1:
  xor eax, eax
  fld dword ptr [esi+40]
  fcomp dword ptr [esi+4]
  fnstsw ax
  test ah, 0x41
  jp 1f
  or ecx, 0x40000
1:
  xor eax, eax
  fld dword ptr [esi+60]
  fcomp qword ptr [esi+104]
  fnstsw ax
  test ah, 0x41
  jnp 1f
  or ecx, 0x80000
1:
  xor eax, eax
  fld dword ptr [esi+60]
  fld dword ptr [esi+16]
  fcompp
  fnstsw ax
  test ah, 0x44
  jz 1f
  or ecx, 0x100000
1:
  xor eax, eax
  fld dword ptr [esi+36]
  fcomp dword ptr [esi+24]
  fnstsw ax
  test ah, 0x44
  jnz 1f
  or ecx, 0x200000
1:
  xor eax, eax
  fld dword ptr [esi+56]
  fcomp qword ptr [esi+96]
  fnstsw ax
  test ah, 0x44
  jp 1f
  or ecx, 0x400000
1:
  xor eax, eax
  fld dword ptr [esi+16]
  fld dword ptr [esi+12]
  fcompp
  fnstsw ax
  test ah, 0x44
  jnp 1f
  or ecx, 0x800000
1:
  xor eax, eax
  fld dword ptr [esi+32]
  fcomp dword ptr [esi+44]
  fnstsw ax
  test ah, 0x45
  jz 1f
  or ecx, 0x1000000
1:
  xor eax, eax
  fld dword ptr [esi+52]
  fcomp qword ptr [esi+88]
  fnstsw ax
  test ah, 0x45
  jnz 1f
  or ecx, 0x2000000
1:
  xor eax, eax
  fld dword ptr [esi+36]
  fld dword ptr [esi+8]
  fcompp
  fnstsw ax
  test ah, 0x45
  jp 1f
  or ecx, 0x4000000
1:
  xor eax, eax
  fld dword ptr [esi+28]
  fcomp dword ptr [esi+0]
  fnstsw ax
  test ah, 0x45
  jnp 1f
  or ecx, 0x8000000
1:
  xor eax, eax
  mov [edi+96], ecx
  mov [edi+100], edx
  pop edi
  pop esi
  mov esp, ebp
  pop ebp
  ret
_t11_end:
