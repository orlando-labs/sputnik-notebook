<script setup lang="ts">
import NotebookTable from './NotebookTable.vue'
import NotebookImages from './NotebookImages.vue'
import NotebookPlot from './NotebookPlot.vue'
import type { RichCell } from './rich'
import NotebookAudio from './NotebookAudio.vue'
defineProps<{ rich: RichCell; identity: string }>()
</script>

<template>
  <div v-if="rich.table || rich.displays.length || rich.images.length || rich.audio?.length || rich.audio_limited || rich.rich_unsupported" class="rich-results" :class="{ 'rich-results-stale': rich.rich_stale }">
    <p v-if="rich.rich_stale" class="rich-stale-note">Previous figures · last successful result</p>
    <NotebookTable v-if="rich.table" :key="`${identity}:result`" :table="rich.table" />
    <template v-for="(figure, index) in rich.displays" :key="`${identity}:display:${figure.id || index}`">
      <NotebookTable v-if="figure.mime === 'application/vnd.sputnik.table+json' && figure.table" :table="figure.table" :caption="figure.caption" />
      <NotebookPlot v-else-if="figure.plot_scene || figure.mime === 'application/vnd.sputnik.plot+json'" :figure="figure" />
      <NotebookImages v-else-if="['image/png', 'image/jpeg'].includes(figure.mime)" :series="{ id: figure.id, caption: figure.caption, images: [figure] }" />
    </template>
    <NotebookImages v-for="series in rich.images" :key="`${identity}:images:${series.id}`" :series="series" />
    <NotebookAudio v-for="(asset, index) in rich.audio || []" :key="`${identity}:audio:${asset.id || index}`" :asset="asset" :stale="rich.audio_stale ?? rich.rich_stale" :controls="rich.audio_controls?.filter(control => control.channel && control.channel === asset.id || !control.channel && rich.audio?.length === 1 && !rich.audio_limited)" />
    <p v-if="rich.audio_limited" class="rich-unavailable" role="status">Some audio exceeds the web result limits and is unavailable. Publish fewer or smaller tracks.</p>
    <p v-if="rich.audio_controls?.some(control => !control.channel) && (rich.audio?.length || 0) > 1" class="rich-unavailable">Choose an audio channel before sending player commands.</p>
    <p v-if="rich.rich_unsupported" class="rich-unavailable">This result also contains a format that is not supported in the web view yet.</p>
  </div>
</template>
