source [file join [file dirname [file normalize [info script]]] .. pakfs.tcl]
proc hexof {bin} { binary scan $bin H* h; return $h }
set out ""
# scenario 1
append out [pak::pakfs_pack {{a.txt hello}}]
append out "\n==SC==\n"
# scenario 2
set s2 [list [list sprites/player.sprite [binary format ccccc 1 2 3 4 5]] \
             [list audio/jump.wav64 [string repeat X 17]] \
             [list empty ""]]
append out [pak::pakfs_pack $s2]
append out "\n==SC==\n"
# scenario 3
set s3 {}
for {set i 0} {$i < 5} {incr i} {
    set n [expr {($i*7) % 40}]
    set d [binary format a$n ""]
    set d [string repeat [binary format c $i] $n]
    lappend s3 [list "f$i" $d]
}
append out [pak::pakfs_pack $s3]
append out "\n==SC==\n"
puts -nonewline [hexof $out]
