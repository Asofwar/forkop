#!/usr/bin/env node
"use strict";

// Meta-check of the source-text assertions in tests/*.sh (UC-154).
//
// Many tests grep production code. A negative check such as
//   if grep -Fq 'pattern' "$FILE"; then fail ...; fi
// passes without reading anything when $FILE was moved, when a recursive grep
// filters its own command-line files out with --include, or when a region cut
// out by sed/awk no longer exists. This script parses every test script
// (a small POSIX shell tokenizer: quotes, $(...), heredocs, pipelines),
// resolves the variables that name repository files and checks each
// grep/sed/awk/find that reads production code:
//   - every named file exists and is not empty, every directory holds files;
//   - a recursive grep with --include/--exclude reads each file named on its
//     command line;
//   - a sed -n or awk extraction whose output is used prints something, and
//     both anchors of a sed /start/,/end/ range match;
//   - every /regex/ an awk program uses to open or close a region matches a
//     line of the file (an awk that looks for a pattern inside a renamed
//     function otherwise reports "not found" and a negative check passes);
//   - no grep -A/-B/-C window of fixed size feeds a negative check: code
//     added past the window would never be read.
//
// Usage: source_assertions.js [--root DIR] [--inventory] TEST.sh...
// Exit status: 0 when every check holds, 1 with one line per problem.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

// ---------------------------------------------------------------------------
// Shell tokenizer: produces simple commands with words made of parts
// { t: "lit", v } | { t: "var", name } | { t: "sub", commands } | { t: "unk" }.

const RESERVED_PREFIX = new Set(["if", "then", "elif", "else", "do", "while", "until", "!", "time", "{"]);
const RESERVED_END = new Set(["fi", "done", "esac", "}"]);

function parseScript(src) {
  const st = { src, i: 0, line: 1, heredocs: [] };
  return parseList(st, false);
}

function parseList(st, inSub) {
  const commands = [];
  let cmd = null;
  let word = null;
  let depth = 0;
  let pipeline = { negated: false };

  const newCmd = () => {
    cmd = { words: [], line: st.line, consumed: inSub, pipeline, sepAfter: null, redirects: [] };
  };
  const addPart = (part) => {
    if (!word) word = { parts: [], line: st.line };
    word.parts.push(part);
  };
  const endWord = () => {
    if (!word) return;
    if (!cmd) newCmd();
    cmd.words.push(word);
    word = null;
  };
  const endCmd = (sep) => {
    endWord();
    if (cmd) {
      cmd.sepAfter = sep;
      if (sep === "|") cmd.consumed = true;
      commands.push(cmd);
    }
    cmd = null;
    if (sep !== "|") pipeline = { negated: false };
  };
  const peek = (k = 0) => st.src[st.i + k];
  const consumeHeredocs = () => {
    while (st.heredocs.length) {
      const doc = st.heredocs.shift();
      for (;;) {
        if (st.i >= st.src.length) return;
        const end = st.src.indexOf("\n", st.i);
        const lineText = st.src.slice(st.i, end < 0 ? st.src.length : end);
        st.i = end < 0 ? st.src.length : end + 1;
        st.line++;
        const text = doc.stripTabs ? lineText.replace(/^\t+/, "") : lineText;
        if (text === doc.delim) break;
      }
    }
  };

  while (st.i < st.src.length) {
    const c = peek();
    if (c === "\\" && peek(1) === "\n") {
      st.i += 2;
      st.line++;
      continue;
    }
    if (c === "\n") {
      st.i++;
      st.line++;
      endCmd("nl");
      consumeHeredocs();
      continue;
    }
    if (c === " " || c === "\t") {
      st.i++;
      endWord();
      continue;
    }
    if (c === "#" && !word) {
      while (st.i < st.src.length && peek() !== "\n") st.i++;
      continue;
    }
    if (c === ")" && inSub && depth === 0) {
      st.i++;
      endCmd("sub");
      return commands;
    }
    if (c === "(" && peek(1) === "(" && !word && (!cmd || cmd.words.length === 0)) {
      // (( arithmetic )) command.
      skipBalanced(st, "(", ")");
      addPart({ t: "unk" });
      continue;
    }
    if (c === "|" || c === "&" || c === ";" || c === "(" || c === ")") {
      if (c === "|" && peek(1) === "|") { st.i += 2; endCmd("||"); continue; }
      if (c === "&" && peek(1) === "&") { st.i += 2; endCmd("&&"); continue; }
      if (c === "|" && peek(1) === "&") { st.i += 2; endCmd("|"); continue; }
      if (c === "&" && peek(1) === ">") { st.i += 2; readRedirect(st, ">", cmd || (newCmd(), cmd), endWord); continue; }
      if (c === ";" && peek(1) === ";") { st.i += 2; endCmd(";;"); continue; }
      st.i++;
      if (c === "(") depth++;
      if (c === ")" && depth > 0) depth--;
      endCmd(c === "|" ? "|" : c);
      continue;
    }
    if (c === "<" || c === ">") {
      // A redirection; digits right before it name the file descriptor.
      let fd = "";
      if (word && /^\d+$/.test(litText(word))) {
        fd = litText(word);
        word = null;
      }
      endWord();
      if (!cmd) newCmd();
      let op = c;
      st.i++;
      while (peek() === "<" || peek() === ">" || peek() === "&" || peek() === "-" || peek() === "|") {
        if (peek() === "-" && op !== "<<") break;
        op += peek();
        st.i++;
      }
      if (op === "<<" || op === "<<-") {
        while (peek() === " " || peek() === "\t") st.i++;
        const delim = readWord(st);
        st.heredocs.push({ delim: litText(delim), stripTabs: op === "<<-" });
        continue;
      }
      readRedirect(st, fd + op, cmd, endWord);
      continue;
    }
    readWordInto(st, addPart);
    continue;
  }
  endCmd("eof");
  return commands;
}

function readRedirect(st, op, cmd, endWord) {
  endWord();
  while (st.src[st.i] === " " || st.src[st.i] === "\t") st.i++;
  const target = /&$/.test(op) && /^[0-9-]/.test(st.src[st.i]) ? { parts: [{ t: "lit", v: st.src[st.i++] }] } : readWord(st);
  cmd.redirects.push({ op, target });
}

function skipBalanced(st, open, close) {
  let depth = 0;
  while (st.i < st.src.length) {
    const c = st.src[st.i];
    if (c === "\n") st.line++;
    if (c === open) depth++;
    if (c === close) {
      depth--;
      if (depth === 0) {
        st.i++;
        return;
      }
    }
    st.i++;
  }
}

function readWord(st) {
  const word = { parts: [], line: st.line };
  readWordInto(st, (part) => word.parts.push(part));
  return word;
}

// Reads one shell word (up to an unquoted blank or operator) into addPart.
function readWordInto(st, addPart) {
  const stop = (c) => c === undefined || " \t\n|&;()<>".includes(c);
  while (!stop(st.src[st.i])) {
    const c = st.src[st.i];
    if (c === "\\") {
      if (st.src[st.i + 1] === "\n") { st.i += 2; st.line++; continue; }
      addPart({ t: "lit", v: st.src[st.i + 1] || "" });
      st.i += 2;
      continue;
    }
    if (c === "'") {
      const end = st.src.indexOf("'", st.i + 1);
      const text = st.src.slice(st.i + 1, end < 0 ? st.src.length : end);
      st.line += (text.match(/\n/g) || []).length;
      addPart({ t: "lit", v: text });
      st.i = end < 0 ? st.src.length : end + 1;
      continue;
    }
    if (c === "$" && st.src[st.i + 1] === "'") {
      st.i += 2;
      let text = "";
      while (st.i < st.src.length && st.src[st.i] !== "'") {
        if (st.src[st.i] === "\\") {
          const e = st.src[st.i + 1];
          text += { n: "\n", t: "\t", "\\": "\\", "'": "'" }[e] ?? "\\" + e;
          st.i += 2;
        } else {
          if (st.src[st.i] === "\n") st.line++;
          text += st.src[st.i++];
        }
      }
      st.i++;
      addPart({ t: "lit", v: text });
      continue;
    }
    if (c === '"') {
      st.i++;
      while (st.i < st.src.length && st.src[st.i] !== '"') {
        const d = st.src[st.i];
        if (d === "\\" && '"\\$`\n'.includes(st.src[st.i + 1])) {
          if (st.src[st.i + 1] === "\n") st.line++;
          else addPart({ t: "lit", v: st.src[st.i + 1] });
          st.i += 2;
          continue;
        }
        if (d === "$") {
          readDollar(st, addPart);
          continue;
        }
        if (d === "`") {
          skipBacktick(st);
          addPart({ t: "unk" });
          continue;
        }
        if (d === "\n") st.line++;
        addPart({ t: "lit", v: d });
        st.i++;
      }
      st.i++;
      continue;
    }
    if (c === "$") {
      readDollar(st, addPart);
      continue;
    }
    if (c === "`") {
      skipBacktick(st);
      addPart({ t: "unk" });
      continue;
    }
    addPart({ t: "lit", v: c, bare: true });
    st.i++;
  }
}

function skipBacktick(st) {
  st.i++;
  while (st.i < st.src.length && st.src[st.i] !== "`") {
    if (st.src[st.i] === "\\") st.i++;
    else if (st.src[st.i] === "\n") st.line++;
    st.i++;
  }
  st.i++;
}

function readDollar(st, addPart) {
  const next = st.src[st.i + 1];
  if (next === "(" && st.src[st.i + 2] === "(") {
    st.i++;
    skipBalanced(st, "(", ")");
    addPart({ t: "unk" });
    return;
  }
  if (next === "(") {
    st.i += 2;
    const raw0 = st.i;
    const commands = parseList(st, true);
    addPart({ t: "sub", commands, raw: st.src.slice(raw0, st.i - 1) });
    return;
  }
  if (next === "{") {
    const end = st.src.indexOf("}", st.i);
    const inner = st.src.slice(st.i + 2, end);
    st.i = end + 1;
    if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(inner)) addPart({ t: "var", name: inner });
    else addPart({ t: "unk" });
    return;
  }
  const m = /^[A-Za-z_][A-Za-z0-9_]*/.exec(st.src.slice(st.i + 1, st.i + 200));
  if (m) {
    st.i += 1 + m[0].length;
    addPart({ t: "var", name: m[0] });
    return;
  }
  if (next !== undefined && /[0-9@*#?$!-]/.test(next)) {
    st.i += 2;
    addPart({ t: "unk" });
    return;
  }
  st.i++;
  addPart({ t: "lit", v: "$" });
}

function litText(word) {
  if (!word) return "";
  return word.parts.map((p) => (p.t === "lit" ? p.v : "\u0000")).join("");
}

// ---------------------------------------------------------------------------
// Variables naming repository paths.

const UNKNOWN = Symbol("unknown");

function resolveWord(word, vars) {
  let out = "";
  for (const p of word.parts) {
    if (p.t === "lit") out += p.v;
    else if (p.t === "var" && typeof vars.get(p.name) === "string") out += vars.get(p.name);
    else return null;
  }
  return out;
}

function hasGlob(word) {
  return word.parts.some((p) => p.t === "lit" && p.bare && /[*?[]/.test(p.v));
}

function isRootSubstitution(word) {
  return word.parts.length === 1 && word.parts[0].t === "sub" &&
    /\bdirname\b/.test(word.parts[0].raw) && /\.\./.test(word.parts[0].raw) && /\bpwd\b/.test(word.parts[0].raw);
}

function recordAssignment(text, word, vars, root) {
  const eq = text.indexOf("=");
  const name = text.slice(0, eq);
  const value = { parts: [] };
  // Drop the literal "NAME=" prefix from the word's parts.
  let skip = eq + 1;
  for (const p of word.parts) {
    if (skip > 0 && p.t === "lit") {
      if (p.v.length <= skip) { skip -= p.v.length; continue; }
      value.parts.push({ ...p, v: p.v.slice(skip) });
      skip = 0;
      continue;
    }
    value.parts.push(p);
  }
  if (isRootSubstitution(value)) {
    vars.set(name, root);
    return;
  }
  const resolved = resolveWord(value, vars);
  const previous = vars.get(name);
  if (resolved === null) vars.set(name, UNKNOWN);
  else if (previous !== undefined && previous !== resolved) vars.set(name, UNKNOWN);
  else vars.set(name, resolved);
}

function commandWords(cmd, vars, root, flow) {
  // Strips reserved words and records assignments; returns the words of the
  // command proper. flow.inCond: the command is part of an if/while
  // condition (between `if` and `then`).
  const words = [...cmd.words];
  while (words.length) {
    const text = litText(words[0]);
    if (RESERVED_PREFIX.has(text)) {
      if (text === "if" || text === "elif" || text === "while" || text === "until") flow.inCond = true;
      if (text === "then" || text === "do" || text === "else") flow.inCond = false;
      if (text === "!") cmd.pipeline.negated = true;
      words.shift();
      continue;
    }
    if (RESERVED_END.has(text)) { words.shift(); continue; }
    break;
  }
  cmd.inCond = flow.inCond;
  if (!words.length) return words;
  const first = litText(words[0]);
  if (first === "for" || first === "select") {
    if (words[1]) vars.set(litText(words[1]), UNKNOWN);
    return [];
  }
  if (first === "case") return [];
  const declare = ["export", "local", "readonly", "declare", "typeset"].includes(first);
  const assigns = [];
  let k = declare ? 1 : 0;
  while (k < words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(litText(words[k]))) {
    assigns.push(words[k]);
    k++;
  }
  if (declare && k < words.length) {
    // `local name` without a value, or options such as `declare -a`.
    for (const w of words.slice(k)) {
      const n = litText(w);
      if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(n)) vars.set(n, UNKNOWN);
    }
  }
  if (k === words.length || declare) {
    for (const w of assigns) recordAssignment(litText(w), w, vars, root);
    return [];
  }
  // A prefix assignment only applies to its command.
  return words.slice(k);
}

// ---------------------------------------------------------------------------
// Command analysis.

function isProductionPath(p, root) {
  if (!p || !path.isAbsolute(p)) return false;
  const rel = path.relative(root, p);
  if (rel === "" || rel.startsWith("..") || path.isAbsolute(rel)) return false;
  const top = rel.split(path.sep)[0];
  return top !== "tests" && top !== ".git" && top !== "node_modules";
}

function run(cmd, args) {
  return spawnSync(cmd, args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
}

function fileHolds(p) {
  let st;
  try {
    st = fs.statSync(p);
  } catch {
    return "is missing";
  }
  if (st.isFile()) return st.size > 0 ? null : "is empty";
  if (st.isDirectory()) {
    const found = run("find", [p, "-type", "f", "-print", "-quit"]);
    return found.stdout.trim() ? null : "holds no files";
  }
  return "is not a file";
}

function globMatch(glob, name) {
  const re = new RegExp("^" + glob.replace(/[.+^${}()|\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$");
  return re.test(name);
}

// grep: options (GNU grep also takes them after the operands), pattern, files.
function parseGrep(args) {
  const out = { recursive: false, includes: [], excludes: [], context: false, pattern: null, files: [], flags: [] };
  const operands = [];
  let patternGiven = false;
  let optionsEnded = false;
  const withArg = new Set(["e", "f", "m", "A", "B", "C", "d", "D"]);
  const longWithArg = ["--include", "--exclude", "--exclude-dir", "--regexp", "--file", "--max-count",
    "--context", "--after-context", "--before-context", "--directories", "--devices", "--label"];
  for (let i = 0; i < args.length; i++) {
    const a = args[i].text;
    if (optionsEnded || a === null || !a.startsWith("-") || a === "-") {
      operands.push(args[i]);
      continue;
    }
    if (a === "--") {
      optionsEnded = true;
      continue;
    }
    if (a.startsWith("--")) {
      const eq = a.indexOf("=");
      const name = eq >= 0 ? a.slice(0, eq) : a;
      let v = eq >= 0 ? a.slice(eq + 1) : null;
      if (longWithArg.includes(name) && v === null) v = args[++i] ? args[i].text : null;
      if (name === "--include") out.includes.push(v);
      if (name === "--exclude") out.excludes.push(v);
      if (name === "--recursive" || name === "--dereference-recursive") out.recursive = true;
      if (/context/.test(name)) out.context = true;
      if (name === "--regexp") { out.pattern = v; patternGiven = true; }
      if (name === "--file") patternGiven = true;
      out.flags.push(name);
      continue;
    }
    for (let k = 1; k < a.length; k++) {
      const f = a[k];
      if (f === "r" || f === "R") out.recursive = true;
      if (withArg.has(f)) {
        const rest = a.slice(k + 1);
        const v = rest !== "" ? rest : args[++i] ? args[i].text : null;
        if (f === "e") { out.pattern = v; patternGiven = true; }
        if (f === "f") patternGiven = true;
        if ("ABC".includes(f)) out.context = true;
        out.flags.push("-" + f);
        break;
      }
      out.flags.push("-" + f);
    }
  }
  if (!patternGiven && operands.length) out.pattern = operands.shift().text;
  out.files = operands;
  return out;
}

function parseSed(args) {
  const out = { quiet: false, extended: false, script: null, files: [], inPlace: false };
  let i = 0;
  let scriptGiven = false;
  for (; i < args.length; i++) {
    const a = args[i].text;
    if (a === null || !a.startsWith("-") || a === "-") break;
    if (a === "--") { i++; break; }
    if (a === "-e" || a === "--expression") { out.script = args[++i] ? args[i].text : null; scriptGiven = true; continue; }
    if (a === "-f") { i++; scriptGiven = true; out.script = null; continue; }
    if (a.startsWith("-i") || a === "--in-place") { out.inPlace = true; continue; }
    if (/^-[nEr]+$/.test(a)) {
      if (a.includes("n")) out.quiet = true;
      if (a.includes("E") || a.includes("r")) out.extended = true;
      continue;
    }
    if (a === "--quiet" || a === "--silent") { out.quiet = true; continue; }
  }
  const operands = args.slice(i);
  if (!scriptGiven && operands.length) out.script = operands.shift().text;
  out.files = operands;
  return out;
}

function parseAwk(args) {
  const out = { program: null, files: [], resolvedVars: true, fs: null };
  let i = 0;
  for (; i < args.length; i++) {
    const a = args[i].text;
    if (a === null) {
      if (args[i - 1] && args[i - 1].text === "-v") { out.resolvedVars = false; continue; }
      break;
    }
    if (a === "--") { i++; break; }
    if (a === "-v") { i++; if (!args[i] || args[i].text === null) out.resolvedVars = false; continue; }
    if (a === "-F") { out.fs = args[++i] ? args[i].text : null; continue; }
    if (a.startsWith("-F")) { out.fs = a.slice(2); continue; }
    if (a.startsWith("-v")) continue;
    if (a === "-f") { i++; out.program = null; return { ...out, files: [] }; }
    if (a.startsWith("-")) continue;
    break;
  }
  if (i < args.length) out.program = args[i++].text;
  out.files = args.slice(i).filter((w) => w.text === null || !/^[A-Za-z_][A-Za-z0-9_]*=/.test(w.text));
  return out;
}

function findPaths(args) {
  const paths = [];
  for (const a of args) {
    if (a.text !== null && (a.text.startsWith("-") || a.text === "(" || a.text === "!")) break;
    paths.push(a);
  }
  return paths;
}

// Regexes of awk rules that only set state, e.g. `/^function x\(/ { copy = 1 }`:
// the region the program inspects starts or ends there.
function awkAnchors(program) {
  const anchors = [];
  const re = /(^|[\n;{}])\s*\/((?:\\.|\[[^\]]*\]|[^/\\\n])+)\/\s*\{\s*[A-Za-z_][A-Za-z0-9_]*\s*=[^=]/g;
  let m;
  while ((m = re.exec(program))) anchors.push(m[2]);
  return anchors;
}

function checkScript(file, root, inventory) {
  const src = fs.readFileSync(file, "utf8");
  const commands = parseScript(src);
  const vars = new Map([["HOME", UNKNOWN]]);
  const problems = [];
  const entries = [];
  const rel = path.relative(root, file);
  const nextOf = new Map();
  const all = [];
  const collect = (list) => {
    for (let k = 0; k < list.length - 1; k++) nextOf.set(list[k], list[k + 1]);
    for (const cmd of list) {
      all.push(cmd);
      for (const w of cmd.words) for (const p of w.parts) if (p.t === "sub") collect(p.commands);
      for (const r of cmd.redirects) for (const p of r.target.parts) if (p.t === "sub") collect(p.commands);
    }
  };
  collect(commands);
  // Variables are followed in file order (function bodies included where they
  // are defined); a variable assigned two different values or from a command
  // is unknown and the paths built from it are not checked.
  all.sort((a, b) => a.line - b.line);

  const flow = { inCond: false };
  // A command's status decides a negative check when it is the condition of
  // an if/while, when `! cmd || fail`, or when `cmd && fail`.
  const decidesNegative = (cmd) => {
    const next = nextOf.get(cmd);
    const negated = cmd.pipeline.negated;
    return (cmd.inCond && !negated) || (negated && cmd.sepAfter === "||") ||
      (!cmd.inCond && cmd.sepAfter === "&&" && next !== undefined && litText(next.words[0]) === "fail");
  };
  // grep -A/-B/-C windows piped on; judged once every command of the
  // pipeline was seen.
  const windows = [];
  for (const cmd of all) {
    const words = commandWords(cmd, vars, root, flow);
    if (!words.length) continue;
    const name = litText(words[0]);
    if (!["grep", "egrep", "fgrep", "sed", "awk", "find"].includes(name)) continue;
    const args = words.slice(1).map((w) => ({ word: w, text: resolveWord(w, vars), glob: hasGlob(w) }));
    const stdoutUsed = cmd.consumed || cmd.redirects.some((r) => /^1?>{1,2}$|^>\|$/.test(r.op) &&
      resolveWord(r.target, vars) !== "/dev/null");
    const where = `${rel}:${cmd.line}`;
    const report = (target, problem) => problems.push(`${where}: ${name} ${target}: ${problem}`);

    let files = [];
    let parsed = null;
    if (name === "grep" || name === "egrep" || name === "fgrep") { parsed = parseGrep(args); files = parsed.files; }
    else if (name === "sed") { parsed = parseSed(args); files = parsed.files; }
    else if (name === "awk") { parsed = parseAwk(args); files = parsed.files; }
    else { files = findPaths(args); }

    const prodFiles = files.filter((f) => f.text !== null && !f.glob && isProductionPath(f.text, root));
    if (!prodFiles.length) continue;
    const negative = decidesNegative(cmd);
    entries.push({ where, name, kind: stdoutUsed ? "extract" : negative ? "negative" : "positive",
      targets: prodFiles.map((f) => path.relative(root, f.text)) });

    for (const f of prodFiles) {
      const problem = fileHolds(f.text);
      if (problem) report(path.relative(root, f.text), problem);
    }

    if (parsed && (name === "grep" || name === "egrep" || name === "fgrep") && parsed.recursive &&
        (parsed.includes.length || parsed.excludes.length)) {
      for (const f of prodFiles) {
        let st;
        try { st = fs.statSync(f.text); } catch { continue; }
        if (!st.isFile()) continue;
        const base = path.basename(f.text);
        const included = !parsed.includes.length || parsed.includes.some((g) => g !== null && globMatch(g, base));
        const excluded = parsed.excludes.some((g) => g !== null && globMatch(g, base));
        if (!included || excluded)
          report(path.relative(root, f.text), "named on the command line but skipped by --include/--exclude, never read");
      }
    }

    if (parsed && parsed.context && cmd.sepAfter === "|")
      windows.push({ cmd, report, target: prodFiles.map((f) => path.relative(root, f.text)).join(" ") });

    const resolvedFiles = files.every((f) => f.text !== null && !f.glob);
    if (name === "grep" && parsed.context && stdoutUsed && parsed.pattern !== null && resolvedFiles) {
      const flags = parsed.flags.filter((f) => /^-[EFGiwx]$/.test(f));
      const out = run("grep", [...flags, "-e", parsed.pattern, "--", ...files.map((f) => f.text)]);
      if (out.status !== 0) report(files.map((f) => path.relative(root, f.text)).join(" "), `extraction /${parsed.pattern}/ matches nothing`);
    }

    if (name === "sed" && parsed.quiet && parsed.script !== null && !parsed.inPlace && resolvedFiles) {
      const flags = parsed.extended ? ["-E"] : [];
      const fileArgs = files.map((f) => f.text);
      if (stdoutUsed) {
        const out = run("sed", [...flags, "-n", parsed.script, ...fileArgs]);
        if (out.status !== 0 || out.stdout === "")
          report(fileArgs.map((f) => path.relative(root, f)).join(" "), `extraction '${parsed.script}' prints nothing`);
      }
      const range = /^\/((?:\\.|[^/\\])+)\/,\/((?:\\.|[^/\\])+)\/p$/.exec(parsed.script);
      if (range) {
        const out = run("sed", [...flags, "-n", `/${range[1]}/,/${range[2]}/{/${range[2]}/=}`, ...fileArgs]);
        const startOut = run("sed", [...flags, "-n", `/${range[1]}/=`, ...fileArgs]);
        if (startOut.stdout === "") report(fileArgs.map((f) => path.relative(root, f)).join(" "), `range start /${range[1]}/ matches nothing`);
        else if (out.stdout === "") report(fileArgs.map((f) => path.relative(root, f)).join(" "), `range end /${range[2]}/ matches nothing after the start (the range runs to the end of the file)`);
      }
    }

    if (name === "awk" && parsed.program !== null && resolvedFiles) {
      const fileArgs = files.map((f) => f.text);
      for (const anchor of awkAnchors(parsed.program)) {
        const out = run("awk", [`/${anchor}/ { n++ } END { print n + 0 }`, ...fileArgs]);
        if (out.status !== 0 || out.stdout.trim() === "0")
          report(fileArgs.map((f) => path.relative(root, f)).join(" "), `region anchor /${anchor}/ matches nothing`);
      }
      if (stdoutUsed && parsed.resolvedVars) {
        const fsArgs = parsed.fs !== null ? ["-F", parsed.fs] : [];
        const out = run("awk", [...fsArgs, parsed.program, ...fileArgs]);
        if (out.stdout === "") report(fileArgs.map((f) => path.relative(root, f)).join(" "), "extraction prints nothing");
      }
    }
  }
  // A fixed window cut out of a function reads only its first lines: once
  // the function grows, a forbidden call added past the window goes unseen
  // and the negative check still passes. A positive check fails loudly.
  for (const w of windows) {
    let end = w.cmd;
    while (end.sepAfter === "|" && nextOf.has(end)) end = nextOf.get(end);
    if (decidesNegative(end))
      w.report(w.target, "a fixed -A/-B/-C window feeds a negative check, code past the window is never read " +
        "(use source_function or source_between)");
  }
  if (inventory) for (const e of entries) inventory.push(e);
  return problems;
}

function main(argv) {
  let root = path.resolve(__dirname, "..", "..");
  let inventory = null;
  const files = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--root") root = path.resolve(argv[++i]);
    else if (argv[i] === "--inventory") inventory = [];
    else files.push(path.resolve(argv[i]));
  }
  if (!files.length) {
    console.error("Usage: source_assertions.js [--root DIR] [--inventory] TEST.sh...");
    return 2;
  }
  const problems = [];
  for (const file of files) problems.push(...checkScript(file, root, inventory));
  if (inventory) {
    const byFile = new Map();
    for (const e of inventory) {
      const key = e.where.replace(/:\d+$/, "");
      const counts = byFile.get(key) || { positive: 0, negative: 0, extract: 0 };
      counts[e.kind]++;
      byFile.set(key, counts);
    }
    for (const e of inventory) console.log(`${e.where}\t${e.kind}\t${e.name}\t${e.targets.join(" ")}`);
    const total = { positive: 0, negative: 0, extract: 0 };
    for (const [file, c] of byFile) {
      console.log(`# ${file}: positive=${c.positive} negative=${c.negative} extract=${c.extract}`);
      for (const k of Object.keys(total)) total[k] += c[k];
    }
    console.log(`# total: files=${byFile.size} positive=${total.positive} negative=${total.negative} extract=${total.extract}`);
  }
  for (const p of problems) console.error(p);
  return problems.length ? 1 : 0;
}

process.exitCode = main(process.argv.slice(2));
