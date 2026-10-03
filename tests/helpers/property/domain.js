"use strict";

// Seeded and exhaustive properties of config/domain.uc against UTS46: a
// domain written in any case reaches the punycode a DNS query carries, as
// browsers and the LuCI form (new URL()) process it (UC-087).
//
// The reference is UTS46 17.0.0, pinned in tests/fixtures/uts46_case_mappings.json
// (the IdnaMappingTable mappings of the cased code points), not the
// url.domainToASCII of the node that runs the test: its UTS46 revision comes
// with the node release (node 20 and 22 map U+1E9E to "ss" and refuse
// U+04C0 and the Georgian capitals; node 24 maps them as UTS46 16 does).
// url.domainToASCII only encodes the folded, lower-case result, which every
// revision treats alike; a code point that this node does not know yet is
// checked by folding alone.
//
//   node domain.js <lib> <work>   run the properties
//   node domain.js --generate <IdnaMappingTable.txt> <DerivedCoreProperties.txt>
//                                 write the fixture from the Unicode data
//                                 files of one version and print the
//                                 UNICODE_FOLD_RANGES of config/domain.uc
//
// The folding table of config/domain.uc: every code point that changes under
// case mapping or case folding (Changes_When_Casemapped,
// Changes_When_Casefolded) and that UTS46 maps to one other code point. UTS46
// maps other cased code points to several (ligatures, digraphs, Roman
// numerals, Greek iota subscript): those are compatibility mappings, not
// case, and config/domain.uc maps only U+0130 among them, whose case mapping
// itself is two code points. ß and ς are deviations, which nontransitional
// processing keeps.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const url = require("node:url");

const FIXTURE = path.join(__dirname, "..", "..", "fixtures", "uts46_case_mappings.json");
const MULTI_FOLDED = new Set([0x130]);

const hex = (cp) => cp.toString(16).toUpperCase().padStart(4, "0");
const codePoints = (field) =>
  field
    .trim()
    .split(/\s+/)
    .filter(Boolean)
    .map((h) => parseInt(h, 16));

// The code points of a Unicode data file whose second field matches.
function* dataLines(text, accept) {
  for (const raw of text.split("\n")) {
    const line = raw.replace(/#.*/, "").trim();
    if (line === "") continue;
    const fields = line.split(";").map((field) => field.trim());
    if (!accept(fields)) continue;
    const [first, last = first] = fields[0].split("..").map((h) => parseInt(h, 16));
    for (let cp = first; cp <= last; cp++) yield [cp, fields];
  }
}

function generate(idnaFile, propertiesFile) {
  const idna = fs.readFileSync(idnaFile, "utf8");
  const properties = fs.readFileSync(propertiesFile, "utf8");
  const uts46 = /^# Version: (\S+)/m.exec(idna)?.[1];
  const unicode = /^# DerivedCoreProperties-(\S+)\.txt/m.exec(properties)?.[1];
  assert.ok(uts46 && unicode, "an IdnaMappingTable.txt and a DerivedCoreProperties.txt");
  assert.equal(uts46, unicode, "the two files of one Unicode version");

  const cased = new Set();
  const caseProperties = ["Changes_When_Casemapped", "Changes_When_Casefolded"];
  for (const [cp] of dataLines(properties, (fields) => caseProperties.includes(fields[1]))) cased.add(cp);

  const mappings = new Map();
  for (const [cp, fields] of dataLines(idna, (fields) => fields[1] === "mapped"))
    if (cp >= 0x80 && cased.has(cp)) mappings.set(cp, codePoints(fields[2]));

  const entries = [...mappings].sort(([a], [b]) => a - b);
  const lines = entries.map(([cp, mapped]) => `    "${hex(cp)}": "${mapped.map(hex).join(" ")}"`);
  fs.writeFileSync(
    FIXTURE,
    `{
  "uts46": "${uts46}",
  "sources": [
    "https://www.unicode.org/Public/${uts46}/idna/IdnaMappingTable.txt",
    "https://www.unicode.org/Public/${unicode}/ucd/DerivedCoreProperties.txt"
  ],
  "generated_by": "node tests/helpers/property/domain.js --generate IdnaMappingTable.txt DerivedCoreProperties.txt",
  "about": "UTS46 mappings of the non-ASCII code points that change under case mapping or case folding",
  "mappings": {
${lines.join(",\n")}
  }
}
`,
  );

  const items = foldRanges(entries).map(([a, b, d, s]) => `[ 0x${a.toString(16)}, 0x${b.toString(16)}, ${d}, ${s} ]`);
  const table = [];
  let line = "   ";
  for (const item of items) {
    if (`${line} ${item},`.length > 100) {
      table.push(line);
      line = "   ";
    }
    line += ` ${item},`;
  }
  table.push(line.replace(/,$/, ""));
  console.log(`// UTS46 ${uts46}: ${items.length} ranges`);
  console.log(table.join("\n"));
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

function loadFixture() {
  const data = JSON.parse(fs.readFileSync(FIXTURE, "utf8"));
  const mappings = Object.entries(data.mappings).map(([cp, mapped]) => [parseInt(cp, 16), codePoints(mapped)]);
  return { uts46: data.uts46, mappings };
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

  const { uts46, mappings } = loadFixture();
  assert.ok(mappings.length > 1000, "the UTS46 case mappings are read");
  const source = fs.readFileSync(`${lib}/config/domain.uc`, "utf8");
  assert.ok(source.includes(`UTS46 ${uts46}`), `config/domain.uc names the UTS46 revision of its table (${uts46})`);

  // What config/domain.uc folds, and the reference folding of a text.
  const folds = new Map(mappings.filter(([cp, m]) => m.length === 1 || MULTI_FOLDED.has(cp)));
  const compatibility = new Set(mappings.filter(([cp]) => !folds.has(cp)).map(([cp]) => cp));
  const fold = (text) =>
    [...text]
      .map((ch) => {
        const mapped = folds.get(ch.codePointAt(0));
        return mapped ? String.fromCodePoint(...mapped) : ch;
      })
      .join("");
  // The punycode of the folded text; "" for a code point this node's UTS46
  // does not know yet (url.domainToASCII refuses it).
  const reference = (text) => url.domainToASCII(fold(text));

  const range = (a, b) => Array.from({ length: b - a + 1 }, (_, i) => String.fromCodePoint(a + i));
  const letter = (ch) => /^\p{L}$/u.test(ch);
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
  // The examples of UC-087, and the letters whose UTS46 mapping changed
  // between revisions (U+1E9E, U+04C0, Georgian Asomtavruli).
  cases.push("Їжак.укр", "Іграшка.укр", "Ґанок.укр", "ЄВРОПА.eu", "Ўсход.бел", "ΕΛΛΆΔΑ.gr", "ŁÓDŹ.pl", "ÇALIŞ.tr",
    "İSTANBUL.tr", "STRAẞE.de", "straße.de", "ӀӀ.example", "ႠႡ.ge");
  const results = domain(cases.map((value) => ({ kind: "suffix", value })));
  let compared = 0;
  forAll(`suffix_to_ascii folds like UTS46 ${uts46}`, seed, cases, (value, i) => {
    const dot = value.startsWith(".") ? "." : "";
    const expected = reference(value.slice(dot.length));
    if (expected === "") return;
    compared++;
    assert.equal(results[i], dot + expected);
  });
  exercised(`suffix_to_ascii folds like UTS46 ${uts46}`, compared, 500);
  const at = (value) => results[cases.indexOf(value)];
  assert.equal(at("Їжак.укр"), "xn--80aln7i.xn--j1amh");
  assert.equal(at("Іграшка.укр"), "xn--80aah3a2a3c8e.xn--j1amh");
  // UTS46 15.1 and later: ẞ maps to ß, which nontransitional processing keeps.
  assert.equal(at("STRAẞE.de"), "xn--strae-oqa.de");
  assert.equal(at("STRAẞE.de"), at("straße.de"));
  assert.equal(at("ӀӀ.example"), "xn--s5aa.example");
  assert.equal(at("ႠႡ.ge"), "xn--rkjc.ge");

  // 2. Normalizing again changes nothing.
  const again = domain(results.filter((r) => r !== null).map((value) => ({ kind: "suffix", value })));
  forAll("suffix_to_ascii is idempotent", seed, results.filter((r) => r !== null), (value, i) =>
    assert.equal(again[i], value));

  // config/domain.uc finds a code point's range by binary search: the table
  // must be sorted and free of overlaps.
  const table = source.slice(source.indexOf("const UNICODE_FOLD_RANGES = ["), source.indexOf("];", source.indexOf("const UNICODE_FOLD_RANGES")));
  const rows = [...table.matchAll(/\[ (0x[0-9a-f]+), (0x[0-9a-f]+), (-?\d+), (\d+) \]/g)].map((m) => [parseInt(m[1], 16), parseInt(m[2], 16)]);
  assert.ok(rows.length > 100, "the folding table of config/domain.uc is read");
  rows.forEach(([first, last], i) => {
    assert.ok(first <= last, `range ${i} is ordered`);
    if (i > 0) assert.ok(first > rows[i - 1][1], `range ${i} starts after range ${i - 1} ends`);
  });

  // 3. Every cased code point UTS46 maps to one code point folds to it (a
  // doubled letter: one label, one script direction), on any node; where
  // this node knows the mapped code point, the punycode is the one UTS46
  // gives.
  const entries = [...folds];
  const doubled = entries.map(([cp]) => String.fromCodePoint(cp).repeat(2));
  const targets = entries.map(([, mapped]) => String.fromCodePoint(...mapped).repeat(2));
  const folded = domain(doubled.map((value) => ({ kind: "suffix", value })));
  const foldedTargets = domain(targets.map((value) => ({ kind: "suffix", value })));
  let checked = 0;
  forAll(`every cased code point folds like UTS46 ${uts46}`, seed, doubled, (value, i) => {
    const name = `U+${hex(value.codePointAt(0))}`;
    assert.notEqual(folded[i], null, name);
    assert.equal(folded[i], foldedTargets[i], name);
    const expected = url.domainToASCII(targets[i]);
    if (expected === "") return;
    checked++;
    assert.equal(folded[i], expected, name);
  });
  exercised(`every cased code point folds like UTS46 ${uts46}`, checked, Math.floor(entries.length * 0.8));

  // 4. Keywords and regular expressions fold their non-ASCII labels the same
  // way; a letter that folds to ASCII (KELVIN SIGN) leaves no raw byte.
  // sing-box matches both against the lower-case domain (strings.ToLower in
  // its domain_keyword and domain_regex items), so an ASCII keyword is
  // lower-cased too. ASCII letters of a regular expression stay as written:
  // a class name (\p{Greek}), a group name or a flag ((?U)) is case
  // sensitive.
  const keywords = Array.from({ length: casesFrom(200) }, () => `${label()}${flipCase(rng.pick(nonAscii))}`);
  const asciiKeywords = Array.from({ length: casesFrom(100) }, () =>
    rng.array(1, 12, () => flipCase(rng.pick(alphabet.filter((ch) => ch < "\x80")))).join(""));
  asciiKeywords.push("YouTube", "GOOGLEVIDEO", "x-Cdn");
  const keywordOut = domain([...keywords, ...asciiKeywords].map((value) => ({ kind: "keyword", value })));
  forAll("keyword_to_ascii folds like UTS46", seed, keywords, (value, i) => {
    const expected = reference(value);
    if (expected !== "") assert.equal(keywordOut[i], expected);
  });
  forAll("keyword_to_ascii lower-cases an ASCII keyword", seed, asciiKeywords, (value, i) =>
    assert.equal(keywordOut[keywords.length + i], value.toLowerCase()));
  const regexLabels = Array.from({ length: casesFrom(200) }, () => [
    `${label()}${flipCase(rng.pick(nonAscii))}`,
    `${flipCase(rng.pick(nonAscii))}${label()}`,
  ]);
  const regexes = regexLabels.map(([a, b]) => `^${a}\\.${b}$`);
  regexes.push("^Key\\.example$", "^\\p{Greek}+\\.Example$");
  const regexOut = domain(regexes.map((value) => ({ kind: "regex", value })));
  forAll("regex_to_ascii folds like UTS46", seed, regexLabels, ([a, b], i) => {
    const ea = reference(a);
    const eb = reference(b);
    if (ea !== "" && eb !== "") assert.equal(regexOut[i], `^${ea}\\.${eb}$`);
  });
  assert.equal(regexOut[regexes.length - 2], "^key\\.example$", "a letter folding to ASCII must not stay raw in a regex");
  assert.equal(regexOut[regexes.length - 1], "^\\p{Greek}+\\.Example$", "ASCII letters of a regex stay as written");

  console.log(`domain normalization properties passed (UTS46 ${uts46}, seed ${seed}, ${compared} domains, ${checked} code points)`);
}

if (process.argv[2] === "--generate") generate(process.argv[3], process.argv[4]);
else run(process.argv[2], process.argv[3]);
