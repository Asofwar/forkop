"use strict";

// Seeded and exhaustive properties of config/domain.uc against the UTS46
// processing of url.domainToASCII (WHATWG URL, the one browsers and LuCI's
// new URL() use): a domain written in any case reaches the same punycode,
// so a rule matches the name a DNS query carries (UC-087).
//
//   node domain.js <lib> <work>   run the properties
//   node domain.js --table        print config/domain.uc UNICODE_FOLD_RANGES
//
// The folding table of config/domain.uc is generated here: every code point
// that changes under case mapping or case folding and that UTS46 maps to one
// other code point. UTS46 mappings to several code points are compatibility
// mappings (ligatures, digraphs, Roman numerals, Greek iota subscript), not
// case: config/domain.uc maps only the two letters among them whose case
// mapping itself is two code points (U+0130, U+1E9E).

const assert = require("node:assert/strict");
const url = require("node:url");

const MULTI_FOLDED = new Set([0x130, 0x1e9e]);
const CASED = /^[\p{Changes_When_Casefolded}\p{Changes_When_Casemapped}]$/u;

function uts46(text) {
  const ascii = url.domainToASCII(text);
  return ascii === "" ? null : url.domainToUnicode(ascii);
}

// [code point, [mapped code points]] for every cased code point UTS46 maps.
function utsCaseMappings() {
  const result = [];
  for (let cp = 0x80; cp <= 0x10ffff; cp++) {
    if (cp >= 0xd800 && cp <= 0xdfff) continue;
    const ch = String.fromCodePoint(cp);
    if (!CASED.test(ch)) continue;
    const mapped = uts46(ch);
    if (mapped === null || mapped === ch) continue;
    result.push([cp, [...mapped].map((c) => c.codePointAt(0))]);
  }
  return result;
}

// [first, last, delta, step]: every step-th code point from first to last maps
// to itself plus delta.
function foldRanges(mappings) {
  const ranges = [];
  for (const [cp, mapped] of mappings) {
    if (mapped.length !== 1) continue;
    const delta = mapped[0] - cp;
    const last = ranges[ranges.length - 1];
    if (last && last[2] === delta) {
      if (last[3] === 0 && (cp === last[1] + 1 || cp === last[1] + 2)) {
        last[3] = cp - last[1];
        last[1] = cp;
        continue;
      }
      if (last[3] !== 0 && cp === last[1] + last[3]) {
        last[1] = cp;
        continue;
      }
    }
    ranges.push([cp, cp, delta, 0]);
  }
  return ranges.map(([first, last, delta, step]) => [first, last, delta, step || 1]);
}

function printTable() {
  const hex = (n) => `0x${n.toString(16)}`;
  const items = foldRanges(utsCaseMappings()).map(([a, b, d, s]) => `[ ${hex(a)}, ${hex(b)}, ${d}, ${s} ]`);
  const lines = [];
  let line = "   ";
  for (const item of items) {
    if (`${line} ${item},`.length > 100) {
      lines.push(line);
      line = "   ";
    }
    line += ` ${item},`;
  }
  lines.push(line.replace(/,$/, ""));
  console.log(`// Unicode ${process.versions.unicode} (node ${process.versions.node}, ICU ${process.versions.icu})`);
  console.log(lines.join("\n"));
}

function run(lib, work) {
  process.env.PROPERTY_WORK = work;
  const { Rng, seedFrom, casesFrom, ucodeBatch, forAll, exercised } = require("./scaffold");
  const seed = seedFrom(20261003);
  const rng = new Rng(seed);
  const domain = (inputs) =>
    ucodeBatch(
      lib,
      `let d = require("config.domain");
function evaluate(input) {
    if (input.kind == "keyword") return d.keyword_to_ascii(input.value);
    if (input.kind == "regex") return d.regex_to_ascii(input.value);
    return d.suffix_to_ascii(input.value);
}`,
      inputs,
    );

  const range = (a, b) => Array.from({ length: b - a + 1 }, (_, i) => String.fromCodePoint(a + i));
  const letter = (ch) => /^\p{L}$/u.test(ch);
  const mappings = utsCaseMappings();
  const compatibility = new Set(mappings.filter(([cp, m]) => m.length > 1 && !MULTI_FOLDED.has(cp)).map(([cp]) => cp));
  const usable = (ch) => letter(ch) && !compatibility.has(ch.codePointAt(0));
  // The scripts of the finding: Latin with Latin-1 and Extended-A
  // (Polish, Turkish), Cyrillic with the Ukrainian and Belarusian letters,
  // Greek with tonos; and Armenian.
  const alphabet = [
    ...range(0x61, 0x7a),
    ...range(0x30, 0x39),
    ...range(0xc0, 0xff),
    ...range(0x100, 0x17f),
    ...range(0x386, 0x3ce),
    ...range(0x400, 0x45f),
    ...range(0x490, 0x4ff),
    ...range(0x531, 0x556),
  ].filter((ch) => /^[0-9]$/.test(ch) || usable(ch));
  const nonAscii = alphabet.filter((ch) => ch.codePointAt(0) >= 0x80);
  const flipCase = (ch) => {
    const other = rng.bool() ? ch.toUpperCase() : ch.toLowerCase();
    return [...other].length === 1 ? other : ch;
  };
  // A label starts with a letter: WHATWG URL reads a name whose last label
  // is a number ("3", "0x1f") as an IPv4 address.
  const letters = alphabet.filter((ch) => !/^[0-9]$/.test(ch));
  const label = () => {
    const chars = [flipCase(rng.pick(letters)), ...rng.array(0, 8, () => flipCase(rng.pick(alphabet)))];
    if (chars.length >= 3 && rng.bool(0.2)) chars.splice(rng.int(1, chars.length - 2), 0, "-");
    return chars.join("");
  };

  // 1. Seeded mixed-case domains (and suffixes with a leading dot).
  const cases = Array.from({ length: casesFrom(600) }, () => {
    const name = rng.array(1, 3, label).join(".");
    return rng.bool(0.2) ? `.${name}` : name;
  });
  // The examples of UC-087.
  cases.push("Їжак.укр", "Іграшка.укр", "Ґанок.укр", "ЄВРОПА.eu", "Ўсход.бел", "ΕΛΛΆΔΑ.gr", "ŁÓDŹ.pl", "ÇALIŞ.tr",
    "İSTANBUL.tr", "STRAẞE.de");
  const results = domain(cases.map((value) => ({ kind: "suffix", value })));
  let compared = 0;
  forAll("suffix_to_ascii folds like UTS46", seed, cases, (value, i) => {
    const dot = value.startsWith(".") ? "." : "";
    const expected = url.domainToASCII(value.slice(dot.length));
    if (expected === "") return;
    compared++;
    assert.equal(results[i], dot + expected);
  });
  exercised("suffix_to_ascii folds like UTS46", compared, 500);
  assert.equal(results[cases.indexOf("Їжак.укр")], "xn--80aln7i.xn--j1amh");
  assert.equal(results[cases.indexOf("Іграшка.укр")], "xn--80aah3a2a3c8e.xn--j1amh");

  // 2. Normalizing again changes nothing.
  const again = domain(results.filter((r) => r !== null).map((value) => ({ kind: "suffix", value })));
  forAll("suffix_to_ascii is idempotent", seed, results.filter((r) => r !== null), (value, i) =>
    assert.equal(again[i], value));

  // 3. Every cased code point UTS46 maps to one code point folds as UTS46 maps
  // it (a doubled letter: one label, one script direction).
  const folds = mappings.filter(([cp, m]) => m.length === 1 || MULTI_FOLDED.has(cp));
  const doubled = folds.map(([cp]) => {
    const ch = String.fromCodePoint(cp);
    return ch + ch;
  });
  const folded = domain(doubled.map((value) => ({ kind: "suffix", value })));
  let checked = 0;
  forAll("every cased code point folds like UTS46", seed, doubled, (value, i) => {
    const expected = url.domainToASCII(value);
    if (expected === "") return;
    checked++;
    assert.equal(folded[i], expected, `U+${value.codePointAt(0).toString(16).toUpperCase()}`);
  });
  exercised("every cased code point folds like UTS46", checked, Math.floor(folds.length * 0.9));

  // 4. Keywords and regular expressions fold their non-ASCII labels the same
  // way; a letter that folds to ASCII (KELVIN SIGN) leaves no raw byte.
  const keywords = Array.from({ length: casesFrom(200) }, () => `${label()}${flipCase(rng.pick(nonAscii))}`);
  const keywordOut = domain(keywords.map((value) => ({ kind: "keyword", value })));
  forAll("keyword_to_ascii folds like UTS46", seed, keywords, (value, i) => {
    const expected = url.domainToASCII(value);
    if (expected !== "") assert.equal(keywordOut[i], expected);
  });
  const regexLabels = Array.from({ length: casesFrom(200) }, () => [
    `${label()}${flipCase(rng.pick(nonAscii))}`,
    `${flipCase(rng.pick(nonAscii))}${label()}`,
  ]);
  const regexes = regexLabels.map(([a, b]) => `^${a}\\.${b}$`);
  regexes.push("^Key\\.example$");
  const regexOut = domain(regexes.map((value) => ({ kind: "regex", value })));
  forAll("regex_to_ascii folds like UTS46", seed, regexLabels, ([a, b], i) => {
    const ea = url.domainToASCII(a);
    const eb = url.domainToASCII(b);
    if (ea !== "" && eb !== "") assert.equal(regexOut[i], `^${ea}\\.${eb}$`);
  });
  assert.equal(regexOut[regexes.length - 1], "^key\\.example$", "a letter folding to ASCII must not stay raw in a regex");

  console.log(`domain normalization properties passed (seed ${seed}, ${compared} domains, ${checked} code points)`);
}

if (process.argv[2] === "--table") printTable();
else run(process.argv[2], process.argv[3]);
