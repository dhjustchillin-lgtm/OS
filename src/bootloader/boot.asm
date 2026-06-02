org 0x7C00 
bits 16 


%define ENDL 0x0D, 0x0A


;
; FAT12 header
;
jmp short start
nop

bdb_oem: db 'MSWIN4.1'  ; 8 bytes
bdb_bytes_per_sector: dw 512
bdb_sectors_per_cluster: db 1
bdb_reserved_sectors: dw 1
bdb_fat_count: db 2
bdb_dir_entries_count: dw 0E0h
bdb_total_sectors: dw 2880
bdb_media_descriptor: db 0F0h
bdb_sectors_per_fat: dw 9
bdb_sectors_per_track: dw 18
bdb_heads: dw 2
bdb_hidden_sectors: dd 0
bdb_large_sector_count: dd 0

; extended boot record (not used, but we need to fill the space)
ebr_drive_number: db 0
    db 0
ebr_signature: db 29h
ebr_volume_id: dd 12h, 34h, 56h, 78h
ebr_volume_label: db 'D-WORKS    '  ; 11 bytes
ebr_file_system_type: db 'FAT12   '  ; 8 bytes

;
; Code goes here
;


start: 
    jmp main


;
; Prints a string to the screen.
; Params:
;   - ds:si points to string
;
puts:
    ; save registers we will modify
    push si
    push ax

.loop:
    lodsb          ; loads next character in al
    or al, al      ; verify if next character is null?
    jz .done

    mov ah, 0x0e   ; call bios interupt 
    mov bh, 0
    int 0x10

    jmp .loop

.done:
    pop bx
    pop ax
    pop si
    ret


main:
    ; setup data segments
    mov ax, 0      ; can't write to ds/es directly
    mov ds, ax
    mov es, ax

    ; setup stack
    mov ss, ax
    mov sp, 0x7C00 ; stack grows downwards

    ; read something from floppy disk
    ; BIOS should set DL to drive number
    mov [ebr_drive_number], dl

    mov ax, 1      ; LBA=1, second sector from disk
    mov cl, 1      ; read 1 sector
    mov bx, 0x7E00 ; read into memory at 0x7E00
    call disk_read

    ; print message
    mov si, msg_hello
    call puts

    cli           ; disable interrupts before halting
    hlt


;
; Error handlers
;

floppy_error:
    mov si, msg_read_failed
    call puts
    jmp wait_key_and_reboot

wait_key_and_reboot:
    mov ah, 0
    int 16h        ; wait for key press
    jmp 0xFFFF:0   ; reboot

.halt:
    cli            ; disable interrupts before halting
    hlt


;
; Disk routines
;

;
; Converts LBA to CHS.
; Params:
;   - ax: LBA sector
; Returns:
;   - cx (bits 0-5): sector number
;   - cx (bits 6-15): cylinder
;   - dh: head
;

lba_to_chs:

    push ax
    push dx

    xor dx, dx                          ; dx = 0
    div word [bdb_sectors_per_track]    ; ax = LBA / SectorsPerTrack
                                        ; dx = LBA % SectorsPerTrack

    inc dx                              ; dx = (LBA % SectorsPerTrack) + 1 = sector
    mov cx, dx                          ; cx = sector

    xor dx, dx                          ; dx = 0
    div word [bdb_heads]                ; ax = (LBA / SectorsPerTrack) / Heads = Cylinder
                                        ; dx = (LBA / SectorsPerTrack) % Heads = Head
    mov dh, dl                          ; dh = head
    mov ch, al                          ; ch = cylinder (lower 8 bits)
    shl ah, 6
    or cl, ah                           ; put upper 2 bits of cylinder in cl
    
    pop ax
    mov dl, al                          ; restore dl
    pop ax
    ret


;
; Reads a sector from disk into memory.
; Params:
;   - ax: LBA address
;   - cl: number of sectors to read (up to 128)
;   - dl: drive number
;   - es:bx: memory address to read into
;
disk_read:

    push ax                 ; save registers we will modify
    push bx
    push cx
    push dx
    push di

    push cx                 ; temporarily save cl (number of sectors to read)
    call lba_to_chs         ; compute CHS
    pop ax                  ; al = number of sectors to read

    mov ah, 02h
    mov di, 3               ; retry count

.retry:
    pusha                  ; save all registers, we don't know which ones the BIOS might modify
    stc                    ; set carry flag before calling BIOS, some BIOS'es don't set it
    int 13h                ; carry flag cleared = success
    jnc .done              ; jump if no carry (success)

    ; failed
    popa
    call disk_reset

    dec di
    test di, di
    jnz .retry

.fail:
    ; after all attemps are exhausted
    jmp floppy_error

.done:
    popa

    pop di                 ; restore registers modified
    pop dx
    pop cx
    pop bx
    pop ax
    ret


;
; Resets the disk controller.
; Params:
;   - dl: drive number
;
disk_reset:
    pusha
    mov ah, 0
    stc
    int 13h
    jc floppy_error
    popa
    ret


msg_hello: db 'Hello world!', ENDL, 0
msg_read_failed: db 'Failed to read from disk!', ENDL, 0

times 510-($-$$) db 0
dw 0AA55h