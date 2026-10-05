// Oracle for cc_slug: the project-dir naming functions copied from the Claude Code 2.1.285 bundle.
//   function h(e){let r=e.replace(/[^a-zA-Z0-9]/g,"-");if(r.length<=_)return r;
//                 return`${r.slice(0,_)}-${Math.abs(F7(e)).toString(36)}`}   with _=200
//   F7(t){let e=0;for(let n=0;n<t.length;n++)e=(e<<5)-e+t.charCodeAt(n)|0;return e}
// Regenerate the fixture with:  node test/oracle/slug_oracle.js > test/fixtures/slug_vectors.tsv
// Output: one vector per line, "<expected slug>\t<input path>". Inputs never contain \t, \n or \r.
"use strict";

const LIMIT = 200;
function F7(t) { let e = 0; for (let n = 0; n < t.length; n++) e = (e << 5) - e + t.charCodeAt(n) | 0; return e; }
function slug(e) {
  const r = e.replace(/[^a-zA-Z0-9]/g, "-");
  if (r.length <= LIMIT) return r;
  return `${r.slice(0, LIMIT)}-${Math.abs(F7(e)).toString(36)}`;
}

// Append characters to `prefix` so that F7(result) === target: vary two salt characters until the
// residue can be met by two final characters c1, c2 (31*c1 + c2 = R) with c2 in a CJK block.
function forceHash(prefix, target) {
  const M = 2n ** 32n;
  const valid = (c) => c >= 0x20 && (c < 0xd800 || c > 0xdfff) && c <= 0xffff;
  for (let a = 0x4e00; a < 0x9f00; a++) {
    for (let b = 0x4e00; b < 0x4e00 + 200; b++) {
      const p = prefix + String.fromCharCode(a) + "zzzzzz" + String.fromCharCode(b);
      const h = BigInt(F7(p) >>> 0);
      const R = Number((((BigInt(target) - h * 961n) % M) + M) % M);
      const c1 = Math.floor((R - 0x4e00) / 31);
      const c2 = R - 31 * c1;
      if (!valid(c1) || !valid(c2)) continue;
      const s = p + String.fromCharCode(c1, c2);
      if (F7(s) === target) return s;
    }
  }
  throw new Error("could not force hash");
}

const long201 = "/home/u/" + "a".repeat(193);            // 201 chars
const vectors = [
  "d:\\Projects\\claude_sync",
  "D:\\Projects\\claude_sync",
  "D:\\Projects\\TransFlow\\apps\\server",
  "C:\\Users\\frank",
  "/mnt/d/Projects/TransFlow",
  "/home/frank/projects/TransFlowX",
  "/root",
  "/",
  "",
  "D:\\Dự án\\Tiếng Việt\\ứng dụng".normalize("NFC"),
  "D:\\Dự án\\Tiếng Việt\\ứng dụng".normalize("NFD"),
  "/home/u/📁 projects/🚀app",
  "/home/u/中文/项目",
  "/home/u/with space/and.dot/and-dash/and_underscore",
  "/home/u/a&b(c)[d]{e}+f=g,h;i'j",
  "/home/u/" + "a".repeat(192),                          // exactly 200 chars
  long201,
  "D:\\" + "VeryLongFolderName\\".repeat(15),
  "/home/u/" + "đường dẫn rất dài ".repeat(12),
  "/home/u/" + "😀".repeat(110),                          // > 200 code units only via surrogates
  forceHash("/home/u/" + "z".repeat(200), -2147483648),  // F7 = -2^31: suffix must be zik0zk
  "\\\\server\\share\\project",
];

for (const v of vectors) {
  if (/[\t\n\r]/.test(v)) throw new Error("vector contains a separator");
  process.stdout.write(`${slug(v)}\t${v}\n`);
}
