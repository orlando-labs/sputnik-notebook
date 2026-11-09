// Markdown and TeX are parsed locally. Only parser-generated HTML is inserted.
const markdown = markdownit({ html: false, linkify: false, maxNesting: 16 })
    .use(texmath, { engine: katex, delimiters: ['dollars', 'brackets'] });

markdown.validateLink = url => /^(?:https?:\/\/|mailto:|#)/i.test(url);
markdown.renderer.rules.image = (tokens, index) =>
    markdown.utils.escapeHtml('[Image: ' + tokens[index].content + ']');
markdown.renderer.rules.table_open = () => '<div class="table-scroll"><table>';
markdown.renderer.rules.table_close = () => '</table></div>';

for (const type of ['math_inline', 'math_inline_double', 'math_block', 'math_block_eqno']) {
    markdown.renderer.rules[type] = (tokens, index) => {
        const token = tokens[index];
        const displayMode = token.block || type === 'math_inline_double';
        let formula;
        try {
            if (token.content.length > 4096) throw new Error('Formula is too long');
            formula = katex.renderToString(token.content, {
                displayMode, output: 'mathml', trust: false, strict: 'ignore', maxExpand: 200, maxSize: 20
            });
        } catch {
            formula = '<span class="math-error">' + markdown.utils.escapeHtml(token.content) + '</span>';
        }
        if (type === 'math_block_eqno') formula += '<span> (' + markdown.utils.escapeHtml(token.info) + ')</span>';
        const tag = token.block ? 'div' : 'span';
        return displayMode ? '<' + tag + ' class="math-display">' + formula + '</' + tag + '>' : formula;
    };
}

function renderNotebookMarkdown(source, theme) {
    const root = document.getElementById('document');
    for (const [name, value] of Object.entries(theme)) {
        document.documentElement.style.setProperty('--' + name, value);
    }
    if (source.length > 262144 || source.split(/\r\n?|\n/).length > 4000) {
        const notice = document.createElement('p');
        notice.textContent = 'Markdown preview is limited to 256 Ki UTF-16 units and 4000 lines.';
        const text = document.createElement('pre');
        text.textContent = source.slice(0, 262144);
        root.replaceChildren(notice, text);
    } else {
        root.innerHTML = markdown.render(source);
    }
}
