.intel_syntax noprefix
.text
.global fwriter_start, fwriter_end
fwriter_start:
    pop r8                       # byte count
    pop r9                       # byte pointer
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 96
    mov r14, r9
    mov r15, r8
    mov r12, -1                  # directory fd
    mov r13, -1                  # output fd
    xor ebx, ebx                 # owned temporary name flag
    movabs rax, 0x747265627265682e # .herbert
    mov [rsp], rax
    mov dword ptr [rsp+24], 0x706d742e # .tmp
    mov byte ptr [rsp+28], 0
    movabs rax, 0x74756f2e61      # a.out\0
    mov [rsp+40], rax
    mov word ptr [rsp+48], 0x2e   # .\0
    mov qword ptr [rsp+72], 128  # collision budget
.Ldir:
    mov eax, 257
    mov edi, -100
    lea rsi, [rsp+48]
    mov edx, 0x90000             # O_DIRECTORY|O_CLOEXEC
    xor r10d, r10d
    syscall
    cmp rax, -4
    je .Ldir
    test rax, rax
    js .Lfail
    mov r12, rax
.Lrandom:
    dec qword ptr [rsp+72]
    js .Lfail
    lea rdi, [rsp+80]
    mov esi, 8
.Lrandom_read:
    mov eax, 318                # getrandom; no insecure fallback
    xor edx, edx
    syscall
    cmp rax, -4
    je .Lrandom_read
    test rax, rax
    jle .Lfail
    cmp rax, rsi
    ja .Lfail
    add rdi, rax
    sub rsi, rax
    jne .Lrandom_read
    mov rax, [rsp+80]
    mov ecx, 16
.Lhex:
    mov edx, eax
    and edx, 15
    add edx, 48
    cmp edx, 57
    jbe .Ldigit
    add edx, 39
.Ldigit:
    mov [rsp+rcx+7], dl
    shr rax, 4
    dec ecx
    jne .Lhex
.Lopen:
    mov eax, 257
    mov rdi, r12
    mov rsi, rsp
    mov edx, 0xa00c1            # O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC
    mov r10d, 420               # 0644, subject to umask
    syscall
    cmp rax, -4
    je .Lopen
    cmp rax, -17
    je .Lrandom
    test rax, rax
    js .Lfail
    mov r13, rax
    mov ebx, 1
.Lwrite:
    test r15, r15
    je .Lsync
    mov eax, 1
    mov rdi, r13
    mov rsi, r14
    mov rdx, r15
    syscall
    cmp rax, -4
    je .Lwrite
    test rax, rax
    jle .Lfail
    cmp rax, r15
    ja .Lfail
    add r14, rax
    sub r15, rax
    jmp .Lwrite
.Lsync:
    mov eax, 74
    mov rdi, r13
    syscall
    cmp rax, -4
    je .Lsync
    test rax, rax
    jne .Lfail
    mov eax, 3
    mov rdi, r13
    mov r13, -1                 # close consumes fd even on Linux EINTR
    syscall
    test rax, rax
    jne .Lfail
.Lrename:
    mov eax, 264
    mov rdi, r12
    mov rsi, rsp
    mov rdx, r12
    lea r10, [rsp+40]
    syscall
    cmp rax, -4
    je .Lrename
    test rax, rax
    jne .Lfail
    mov eax, 3                  # directory cleanup after publication
    mov rdi, r12
    syscall                     # cannot undo committed rename on cleanup error
    add rsp, 96
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    jmp fwriter_end
.Lfail:
    test r13, r13
    js .Lunlink
    mov eax, 3
    mov rdi, r13
    syscall                     # never retry Linux close
.Lunlink:
    test ebx, ebx
    je .Lclose_dir
.Lunlink_retry:
    mov eax, 263
    mov rdi, r12
    mov rsi, rsp
    xor edx, edx
    syscall
    cmp rax, -4
    je .Lunlink_retry
.Lclose_dir:
    test r12, r12
    js .Ldiagnostic
    mov eax, 3
    mov rdi, r12
    syscall
.Ldiagnostic:
    lea rsi, [rip+.Lmessage]
    mov edx, .Lmessage_end-.Lmessage
.Lreport:
    mov eax, 1
    mov edi, 2
    syscall
    cmp rax, -4
    je .Lreport
    test rax, rax
    jle .Lexit
    add rsi, rax
    sub rdx, rax
    jne .Lreport
.Lexit:
    mov eax, 231
    mov edi, 1
    syscall
    ud2
.Lmessage:
    .ascii "compiler: output publication failed\n"
.Lmessage_end:
fwriter_end:
