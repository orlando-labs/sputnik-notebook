<script setup lang="ts">
defineProps<{ name: 'book' | 'plus' | 'folder' | 'chevron' | 'refresh' | 'back' | 'arrow' | 'github' | 'close' | 'search' | 'copy' | 'sheet' | 'save' | 'up' | 'down' | 'trash' | 'play' | 'stop' }>()
</script>

<template>
  <svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <template v-if="name === 'book'">
      <path d="M6 3.5h12a1 1 0 0 1 1 1v16H6a2 2 0 0 1-2-2v-13a2 2 0 0 1 2-2Z" />
      <path d="M4 17h15M8 3.5V17M11.5 7.5h4M11.5 10.5h4" />
    </template>
    <path v-else-if="name === 'plus'" d="M12 5v14M5 12h14" />
    <path v-else-if="name === 'folder'" d="M3 7a2 2 0 0 1 2-2h5l2 3h7a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z" />
    <path v-else-if="name === 'chevron'" d="m9 5 7 7-7 7" />
    <path v-else-if="name === 'refresh'" d="M20 5v5h-5M20 10a8 8 0 1 0-.8 7" />
    <path v-else-if="name === 'back'" d="m14 6-6 6 6 6" />
    <path v-else-if="name === 'arrow'" d="M5 12h14m-6-6 6 6-6 6" />
    <path v-else-if="name === 'close'" d="m6 6 12 12M6 18 18 6" />
    <path v-else-if="name === 'sheet'" d="M6 3h8l4 4v14H6ZM14 3v5h4M9 12h6M9 16h6" />
    <path v-else-if="name === 'save'" d="M4 3h13l4 4v14H3V3ZM7 3v6h10V3M7 21v-8h10v8" />
    <path v-else-if="name === 'up'" d="M12 19V5m-6 6 6-6 6 6" />
    <path v-else-if="name === 'down'" d="M12 5v14m-6-6 6 6 6-6" />
    <path v-else-if="name === 'trash'" d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7" />
    <path v-else-if="name === 'play'" fill="currentColor" stroke="none" d="M7 4.5a1 1 0 0 1 1.5-.86l12 7.5a1 1 0 0 1 0 1.72l-12 7.5A1 1 0 0 1 7 19.5Z" />
    <rect v-else-if="name === 'stop'" x="5" y="5" width="14" height="14" rx="2" fill="currentColor" stroke="none" />
    <template v-else-if="name === 'search'">
      <circle cx="10.5" cy="10.5" r="6.5" /><path d="m16 16 4.5 4.5" />
    </template>
    <template v-else-if="name === 'copy'">
      <rect x="8" y="8" width="12" height="13" rx="2" /><path d="M16 8V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h3" />
    </template>
    <path v-else-if="name === 'github'" stroke="none" fill="currentColor" d="M12 2a10 10 0 0 0-3.16 19.49c.5.09.68-.22.68-.48v-1.86c-2.78.6-3.37-1.18-3.37-1.18-.45-1.16-1.11-1.47-1.11-1.47-.91-.62.07-.61.07-.61 1 .07 1.53 1.03 1.53 1.03.89 1.52 2.34 1.08 2.91.83.09-.65.35-1.08.64-1.33-2.22-.25-4.55-1.11-4.55-4.94 0-1.09.39-1.99 1.03-2.69-.1-.25-.45-1.27.1-2.65 0 0 .84-.27 2.75 1.03A9.6 9.6 0 0 1 12 6.83c.85 0 1.71.11 2.51.34 1.91-1.3 2.75-1.03 2.75-1.03.55 1.38.2 2.4.1 2.65.64.7 1.03 1.6 1.03 2.69 0 3.84-2.34 4.68-4.57 4.93.36.31.68.92.68 1.85v2.75c0 .27.18.58.69.48A10 10 0 0 0 12 2Z" />
  </svg>
</template>
