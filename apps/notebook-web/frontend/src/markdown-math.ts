import { defineComponent, h, ref, watchPostEffect } from 'vue'
import katex from 'katex'
import texmath from 'markdown-it-texmath'
import { createMarkdownParser } from './markdown'

export const documentParser = createMarkdownParser().use(texmath, { engine: katex, delimiters: ['dollars', 'brackets'] })

export const Formula = defineComponent({
  props: { source: { type: String, required: true }, display: Boolean, block: Boolean, number: String },
  setup(props) {
    const output = ref<HTMLElement>()
    watchPostEffect(() => {
      const target = output.value
      if (!target) return
      try {
        if (props.source.length > 4096) throw new Error('Formula is too long.')
        katex.render(props.source, target, { displayMode: props.display, output: 'mathml', trust: false, strict: 'ignore', maxExpand: 200, maxSize: 20 })
        target.classList.remove('markdown-math-error')
      } catch {
        target.textContent = props.source
        target.classList.add('markdown-math-error')
      }
    })
    return () => h(props.block ? 'div' : 'span', { class: props.display ? 'markdown-math-display' : 'markdown-math-inline' }, [
      h('span', { ref: output }),
      props.number ? h('span', ' (' + props.number + ')') : null,
    ])
  }
})
