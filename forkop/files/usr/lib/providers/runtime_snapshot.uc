let fs = require("fs");
let process_identity = require("core.process_identity");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let words = [];
    for (let arg in args)
        push(words, shell_quote(arg));
    return join(" ", words);
}

function command_success(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function first_line(path) {
    let data = fs.readfile(path);
    if (data == null)
        return "";
    return trim(split(data, "\n")[0]);
}

function pidfiles(path) {
    if (fs.stat(path) == null)
        return [];
    let stream = fs.popen(command_from_args([ "find", path, "-maxdepth", "1", "-type", "f", "-name", "*.pid" ]), "r");
    if (stream == null)
        return [];
    let result = [];
    let line;
    while ((line = stream.read("line")) != null) {
        line = trim(line);
        if (line != "")
            push(result, line);
    }
    stream.close();
    return result;
}

function running(pid) {
    return match(as_string(pid), /^[0-9]+$/) != null && command_success([ "kill", "-0", pid ]);
}

function snapshot(pid_dir, child_pid_dir, runtime_path, library_path, output_path) {
    let entries = [];
    for (let child_file in pidfiles(child_pid_dir)) {
        let child = process_identity.read_record(child_file);
        if (child == null)
            return false;
        if (running(child.pid)) {
            let parent_file = pid_dir + "/" + replace(child_file, /^.*\//, "");
            let parent = process_identity.read_record(parent_file);
            if (parent == null || !running(parent.pid))
                return false;
        }
    }
    for (let pidfile in pidfiles(pid_dir)) {
        let saved = process_identity.read_record(pidfile);
        if (saved == null)
            return false;
        let pid = saved.pid;
        let name = replace(replace(pidfile, /^.*\//, ""), /\.pid$/, "");
        if (!running(pid)) {
            let child_file = child_pid_dir + "/" + name + ".pid";
            let child = fs.stat(child_file) == null ? null : process_identity.read_record(child_file);
            if (fs.stat(child_file) != null && (child == null || running(child.pid)))
                return false;
            push(entries, { stale: name });
            continue;
        }
        if (saved.ticks != "" && process_identity.start_ticks(pid) != saved.ticks)
            return false;
        let raw = fs.readfile("/proc/" + pid + "/cmdline");
        if (raw == null)
            return false;
        let args = split(raw, "\0");
        if (length(args) > 0 && args[length(args) - 1] == "")
            pop(args);
        if (length(args) != 9 ||
            !match(args[0], /(^|\/)ucode$/) || args[1] != "-L" ||
            args[2] != library_path || args[3] != runtime_path ||
            args[4] != "supervisor" || args[5] != name ||
            args[8] != child_pid_dir + "/" + name + ".pid")
            return false;
        push(entries, { name, args });
    }
    return fs.writefile(output_path, sprintf("%J\n", entries)) != null;
}

function restore(input_path, pid_dir, child_pid_dir, log_dir, runtime_path, library_path) {
    let data = fs.readfile(input_path);
    if (data == null)
        return false;
    let entries;
    try { entries = json(data); }
    catch (e) { return false; }
    if (type(entries) != "array")
        return false;
    if (!command_success([ "mkdir", "-p", pid_dir, child_pid_dir, log_dir ]))
        return false;
    let stale = false;
    for (let entry in entries) {
        if (entry && type(entry.stale) == "string" &&
            match(entry.stale, /^[A-Za-z0-9_.-]+$/) != null) {
            stale = true;
            continue;
        }
        let name = entry && entry.name;
        let args = entry && entry.args;
        if (type(name) != "string" || !match(name, /^[A-Za-z0-9_.-]+$/) ||
            type(args) != "array" || length(args) != 9 ||
            !match(args[0], /(^|\/)ucode$/) || args[1] != "-L" ||
            args[2] != library_path || args[3] != runtime_path ||
            args[4] != "supervisor" || args[5] != name ||
            args[8] != child_pid_dir + "/" + name + ".pid")
            return false;
        let logfile = log_dir + "/" + name + ".log";
        let launch = command_from_args(args) + " >>" + shell_quote(logfile) + " 2>&1 1000>&- & echo $!";
        let stream = fs.popen("sh -c " + shell_quote(launch), "r");
        if (stream == null)
            return false;
        let pid = trim(stream.read("line") || "");
        stream.close();
        if (!running(pid) || !process_identity.record(pid_dir + "/" + name + ".pid", pid))
            return false;
        command_success([ "sleep", "1" ]);
        if (!running(pid) || !running(first_line(child_pid_dir + "/" + name + ".pid")))
            return false;
    }
    return !stale;
}

return { snapshot, restore };
