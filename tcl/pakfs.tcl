# tcl/pakfs.tcl — PakFS archive format (pack/unpack).
# Little-endian binary layout:
#   header: "PKFS"(4) version:u16 num_files:u16 index_off:u32
#   index:  per file -> name_len:u16 name offset:u32 size:u32 flags:u16
#   data:   raw bytes, 16-byte aligned
# Callers pass/receive `data` as binary strings (bytes 0..255).

namespace eval pak {}
if {[info exists ::pak::_pakfs_loaded]} { return }
set ::pak::_pakfs_loaded 1

set ::pak::PAKFS_MAGIC "PKFS"
set ::pak::PAKFS_VERSION 1

# files: list of {name data} pairs. Returns the archive as a binary string.
proc pak::pakfs_pack {files} {
    set index_size 0
    foreach pair $files {
        lassign $pair name data
        set nb [encoding convertto utf-8 $name]
        incr index_size [expr {2 + [string length $nb] + 4 + 4 + 2}]
    }
    set header_size 12
    set index_offset $header_size
    set data_start [expr {$header_size + $index_size}]
    set data_start [expr {($data_start + 15) & ~15}]

    set index_entries {}
    set data_chunks {}
    set current_offset $data_start
    foreach pair $files {
        lassign $pair name data
        set nb [encoding convertto utf-8 $name]
        set dlen [string length $data]
        set padded_size [expr {($dlen + 15) & ~15}]
        # Pad data to padded_size with nulls.
        set padded_data [binary format a$padded_size $data]
        lappend index_entries [list $nb $current_offset $dlen]
        lappend data_chunks $padded_data
        incr current_offset $padded_size
    }

    set out [binary format a4 $::pak::PAKFS_MAGIC]
    append out [binary format ssi $::pak::PAKFS_VERSION [llength $files] $index_offset]
    foreach e $index_entries {
        lassign $e nb offset size
        append out [binary format s [string length $nb]]
        append out $nb
        append out [binary format iis $offset $size 0]
    }
    # Pad to data_start.
    set pad [expr {$data_start - [string length $out]}]
    if {$pad > 0} { append out [binary format a$pad ""] }
    foreach chunk $data_chunks { append out $chunk }
    return $out
}

# Returns list of {name data} pairs.
proc pak::pakfs_unpack {data} {
    if {[string range $data 0 3] ne $::pak::PAKFS_MAGIC} {
        return -code error "Not a PakFS archive (bad magic)"
    }
    binary scan $data "@4 ssi" version num_files index_offset
    set version [expr {$version & 0xFFFF}]
    set num_files [expr {$num_files & 0xFFFF}]
    if {$version != $::pak::PAKFS_VERSION} {
        return -code error "Unsupported PakFS version: $version"
    }
    set files {}
    set pos $index_offset
    for {set k 0} {$k < $num_files} {incr k} {
        binary scan $data "@$pos s" name_len
        set name_len [expr {$name_len & 0xFFFF}]
        incr pos 2
        set name [encoding convertfrom utf-8 [string range $data $pos [expr {$pos + $name_len - 1}]]]
        incr pos $name_len
        binary scan $data "@$pos iis" offset size flags
        incr pos 10
        set file_data [string range $data $offset [expr {$offset + $size - 1}]]
        lappend files [list $name $file_data]
    }
    return $files
}
