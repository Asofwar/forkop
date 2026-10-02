#!/usr/bin/env ucode

// Durable replacement of a file on flash (UC-025).
//
// A rename alone does not make a new file durable on UBIFS, the NAND overlay
// of many routers: the rename reaches the flash within seconds, the data of
// the new file only with the write-back (about 30 s), so a power cut in
// between leaves the file empty. ucode has no fsync: sync(1) flushes the new
// file before the rename makes it the file, and the rename right after it,
// as libuci does for its commits. sync flushes every filesystem and may take
// long with much dirty data (USB storage): only rare, critical writes use
// it, never a file rewritten on every poll.
//
// fs.writefile reports a small file as written when the filesystem is full
// (stdio writes it on close, and that error is lost): the temporary file is
// read back before it replaces anything.

let fs = require("fs");

function flush() {
    return system("sync >/dev/null 2>&1") == 0;
}

// Makes data the content of path. tmp: the caller's temporary file next to
// path, unique per writer; mode: its permissions (null: as created).
// True when path holds data; otherwise tmp is gone and path is unchanged.
function durable_replace(tmp, path, data, mode) {
    data = data == null ? "" : "" + data;
    if (fs.writefile(tmp, data) == null || (mode != null && !fs.chmod(tmp, mode)) ||
        fs.readfile(tmp) !== data || !flush() || !fs.rename(tmp, path)) {
        fs.unlink(tmp);
        return false;
    }
    // Renamed: path holds data, whatever this flush reports.
    flush();
    return true;
}

return { durable_replace };
