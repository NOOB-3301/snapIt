// Runs the answer renderer's md() in Node against the vendored marked/KaTeX: node tools/renderer.check.js
const fs = require('fs');
const path = require('path');
const dir = path.join(__dirname, '..', 'Resources', 'web');
const html = fs.readFileSync(path.join(dir, 'index.html'), 'utf8');
const inline = html.split('<script>')[1].split('</script>')[0];
global.marked = require(path.join(dir, 'marked.min.js'));
global.katex = require(path.join(dir, 'katex.min.js'));
eval(inline.slice(0, inline.indexOf('function render')));

let fail = 0;
const check = (name, ok, detail) => {
  if (!ok) { fail++; console.log('FAIL ' + name + (detail ? ' :: ' + String(detail).slice(0, 200) : '')); }
};
const renders = (name, src) => {
  try {
    const out = md(src);
    check(name, !/undefined|\[object Object\]|\uE000|\uE001/.test(out), out);
    return out;
  } catch (e) { check(name + ' (threw)', false, e.message); return ''; }
};

const fence = String.fromCharCode(96).repeat(3);
renders('inline math', 'Energy is $E = mc^2$.');
renders('display math', '$$\\int_0^1 x^2 dx = \\frac{1}{3}$$');
renders('latex delimiters', '\\(a^2\\) and \\[b^2\\]');
renders('code block', fence + 'swift\nlet x = 1\n' + fence);
renders('table', '| a | b |\n|---|---|\n| 1 | 2 |');

check('katex renders inline and display', (renders('both', '$x^2$ and $$y_3$$').match(/class="katex/g) || []).length >= 2);
const literal = renders('literal dollar', 'It costs \\$5 and \\$10.');
check('literal dollar is not treated as math', literal.includes('$5') && !literal.includes('katex'), literal);
const image = renders('image', '![alt](https://example.com/a.png)');
check('image becomes a link, never a remote load', image.includes('<a href="https://example.com/a.png"') && !image.includes('<img'), image);
check('raw html is escaped', !renders('html', '<script>alert(1)</script>').includes('<script>'));
check('web link kept', renders('link', '[store](https://shop.example/cpu)').includes('href="https://shop.example/cpu"'));

for (const scheme of ['javascript:alert(1)', 'JaVaScRiPt:alert(1)', 'data:text/html,<b>x</b>', 'vbscript:x', 'file:///etc/passwd']) {
  for (const src of ['[x](' + scheme + ')', '![x](' + scheme + ')']) {
    const out = renders('scheme ' + scheme, src);
    check('no clickable ' + scheme, !/href\s*=\s*"(javascript|data|vbscript|file):/i.test(out), out);
  }
}

console.log(fail === 0 ? 'renderer.check: ok' : 'renderer.check: ' + fail + ' failures');
process.exit(fail === 0 ? 0 : 1);