package base

import "core:crypto/md5"

StrHash :: distinct u128

hash :: proc(s: string) -> StrHash {
    return transmute(StrHash)(md5.hash(s))
}