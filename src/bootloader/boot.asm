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
    ; setup data segments
    mov ax, 0      ; can't write to ds/es directly
    mov ds, ax
    mov es, ax

    ; setup stack
    mov ss, ax
    mov sp, 0x7C00 ; stack grows downwards
    
    ; some BIOSes might start us at 07C0:0000 instead of 0000:7C00, so we need to adjust the stack pointer

    push es
    push word .after
    retf

.after:

    ; read something from floppy disk
    ; BIOS should set DL to drive number
    mov [ebr_drive_number], dl

    ; print message
    mov si, msg_loading
    call puts

    ; read drive parameters (sectors per track and head count),
    ; instead of relying on data on formatted disk
    push es
    mov ah, 08h
    int 13h
    jc floppy_error
    pop es

    and cl, 0x3F                       ; remove top 2 bits
    xor ch, ch
    mov [bdb_sectors_per_track], cx     ; sector count

    inc dh
    mov [bdb_heads], dx                 ; head count

    ; compute LBA of root directory = reserved + fats * sectors_per_fat
    ; note: this section can be hardcoded
    mov ax, [bdb_sectors_per_fat]
    mov bl, [bdb_fat_count]
    xor bh, bh
    mul bx                              ; ax = (fats * sectors_per_fat)
    add ax, [bdb_reserved_sectors]      ; ax = LBA of root directory
    push ax

    ; compute size of root directory in sectors = (32 * number of entries) / bytes per sector
    mov ax, [bdb_sectors_per_fat]
    shl ax, 5                           ; ax = 32 * number of entries
    xor dx, dx                          ; dx = 0
    div word [bdb_bytes_per_sector]     ; number of sectors we need to read for root directory
    
    test dx, dx                         ; if there is a remainder, we need to read one more sector
    jz .root_dir_after
    inc ax                              ; remainder != 0, add 1
                                        ; this means we have a sector only partially filled with directory entries, but we still need to read it to get all the entries
.root_dir_after:

    ; read root directory into memory at 0x8000
    mov cl, al                          ; cl = number of sectors to read = size of root directory
    pop ax                              ; ax = LBA of root directory
    mov dl, [ebr_drive_number]          ; dl = drive number (we saved it previously)
    mov bx, buffer                      ; es:bx = memory address to read into
    call disk_read

    ; search for kernel.bin
    xor bx, bx
    mov di, buffer

.search_kernel:
    mov si, file_kernel_bin
    mov cx, 11                          ; compare 11 bytes (length of filename in directory entry)
    push di
    repe cmpsb
    pop di
    jz .found_kernel                     ; if we found the file, jump to .found_kernel

    add di, 32                          ; move to next directory entry (each entry is 32 bytes)
    inc bx
    cmp bx, [bdb_dir_entries_count]     ; have we checked all directory entries?
    jb .search_kernel

    ; kernel.bin not found
    jmp kernel_not_found_error

.found_kernel:

    ; di should have the address to the entry
    mov ax, [di + 26]                   ; ax = starting cluster of file (offset 26 in directory entry)
    mov [kernel_cluster], ax

    ; load FAT from disk into memory
    mov ax, [bdb_reserved_sectors]
    mov bx, buffer
    mov cl, [bdb_sectors_per_fat]
    mov dl, [ebr_drive_number]
    call disk_read

    ; read kernel and process FAT chain
    mov bx, KERNEL_LOAD_SEGMENT
    mov es, bx
    mov bx, KERNEL_LOAD_OFFSET

.load_kernel_loop:

    ; Read next cluster
    mov ax, [kernel_cluster]

    ; not nice :( hardcoded value
    add ax, 31                          ; first cluster = (kernel cluster - 2) * sectors_per_cluster + start sector
                                        ; start sector = reserved + fats + root directory size = 1 + 18 + 134 = 33
    mov cl, 1
    mov dl, [ebr_drive_number]
    call disk_read

    add bx, [bdb_bytes_per_sector]

    ; compute location of next cluster
    mov ax, [kernel_cluster]
    mov cx, 3
    mul cx
    mov cx, 2
    div cx                              ; ax = index of entry in FAT, dx = cluster mod 2

    mov si, buffer
    add si, ax
    mov ax, [ds:si]                     ; read entry from FAT table at index ax

    or dx, dx
    jz .even

.odd:
    shr ax, 4
    jmp .next_cluster_after

.even:
    and ax, 0x0FFF

.next_cluster_after:
    cmp ax, 0x0FF8                      ; end of chain
    jae .read_finish

    mov [kernel_cluster], ax
    jmp .load_kernel_loop

.read_finish:

    ; jump to our kernel
    mov dl, [ebr_drive_number]          ; boot device in dl

    mov ax, KERNEL_LOAD_SEGMENT         ; set segment registers
    mov ds, ax
    mov es, ax

    jmp KERNEL_LOAD_SEGMENT:KERNEL_LOAD_OFFSET

    jmp wait_key_and_reboot             ; should never happen

    cli                                 ; disable interrupts while reading from disk, some BIOSes might not like interrupts during disk access
    hlt


;
; Error handlers
;

floppy_error:
    mov si, msg_read_failed
    call puts
    jmp wait_key_and_reboot

kernel_not_found_error:
    mov si, msg_kernel_not_found
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
    pop ax
    pop si
    ret

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


msg_loading: db 'Loading...', ENDL, 0
msg_read_failed: db 'Read failure!', ENDL, 0
msg_kernel_not_found: db 'Kernel not found!', ENDL, 0
file_kernel_bin: db 'KERNEL  BIN'  ; 11 bytes, padded with spaces
kernel_cluster: dw 0

KERNEL_LOAD_SEGMENT equ 0x2000
KERNEL_LOAD_OFFSET equ 0

times 510-($-$$) db 0
dw 0AA55h

buffer: