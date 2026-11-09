declare module 'markdown-it-texmath' {
  import MarkdownIt from 'markdown-it'
  export default function texmath(parser: InstanceType<typeof MarkdownIt>, options: { engine: { renderToString: (source: string) => string }; delimiters: string[] }): void
}
