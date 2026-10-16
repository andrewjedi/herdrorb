const hljs = require('highlight.js/lib/core');
hljs.registerLanguage('bash', require('highlight.js/lib/languages/bash'));
hljs.registerLanguage('css', require('highlight.js/lib/languages/css'));
hljs.registerLanguage('diff', require('highlight.js/lib/languages/diff'));
hljs.registerLanguage('go', require('highlight.js/lib/languages/go'));
hljs.registerLanguage('ini', require('highlight.js/lib/languages/ini'));
hljs.registerLanguage('java', require('highlight.js/lib/languages/java'));
hljs.registerLanguage('javascript', require('highlight.js/lib/languages/javascript'));
hljs.registerLanguage('json', require('highlight.js/lib/languages/json'));
hljs.registerLanguage('kotlin', require('highlight.js/lib/languages/kotlin'));
hljs.registerLanguage('markdown', require('highlight.js/lib/languages/markdown'));
hljs.registerLanguage('objectivec', require('highlight.js/lib/languages/objectivec'));
hljs.registerLanguage('php', require('highlight.js/lib/languages/php'));
hljs.registerLanguage('python', require('highlight.js/lib/languages/python'));
hljs.registerLanguage('ruby', require('highlight.js/lib/languages/ruby'));
hljs.registerLanguage('rust', require('highlight.js/lib/languages/rust'));
hljs.registerLanguage('sql', require('highlight.js/lib/languages/sql'));
hljs.registerLanguage('swift', require('highlight.js/lib/languages/swift'));
hljs.registerLanguage('typescript', require('highlight.js/lib/languages/typescript'));
hljs.registerLanguage('xml', require('highlight.js/lib/languages/xml'));
hljs.registerLanguage('yaml', require('highlight.js/lib/languages/yaml'));
const decode = s => s.replace(/&(?:amp|lt|gt|quot|#x27|#39);/g, e => ({'&amp;':'&','&lt;':'<','&gt;':'>','&quot;':'"','&#x27;':"'",'&#39;':"'"}[e]));
globalThis.herdrHighlight = function(source, language) {
  if (!hljs.getLanguage(language)) return [{text: source, scope: ''}];
  const html = hljs.highlight(source, {language, ignoreIllegals:true}).value;
  const stack = [], tokens = [];
  const regex = /<span class="([^"]*)">|<\/span>|([^<]+)/g;
  let m;
  while ((m = regex.exec(html))) {
    if (m[1]) stack.push(m[1]);
    else if (m[0] === '</span>') stack.pop();
    else if (m[2]) tokens.push({text:decode(m[2]),scope:stack.join(' ')});
  }
  return tokens;
};
