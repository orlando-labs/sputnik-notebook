<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { downloadRaster, rasterURL, type ImageSeries } from './rich'
const props = withDefaults(defineProps<{ series: ImageSeries; mode?: string; allowSave?: boolean }>(), { allowSave: true })
const index = ref(0)
const failed = ref(false)
const image = computed(() => props.series.images[index.value])
const url = computed(() => image.value ? rasterURL(image.value) : '')
watch(() => props.series, () => { index.value = Math.min(index.value, Math.max(0, props.series.images.length - 1)) })
watch(url, () => { failed.value = false })
</script>

<template>
  <section class="rich-images" aria-label="Image result" data-testid="rich-images">
    <h3 v-if="series.caption" class="figure-caption">{{ series.caption }}</h3>
    <div class="image-viewport" :class="mode ? 'image-mode-' + mode : ''"><img v-if="image && url && !failed" :src="url" :alt="image.caption || series.caption || 'Notebook image'" :width="image.width" :height="image.height" @error="failed = true">
      <p v-else class="rich-unavailable">{{ image ? 'Image preview unavailable' : 'No images in this collection' }}</p>
    </div>
    <p v-if="image?.caption && image.caption !== series.caption" class="image-caption">{{ image.caption }}</p>
    <div class="figure-footer">
      <span v-if="series.images.length > 1" class="image-pagination"><button aria-label="Previous image" :disabled="index === 0" @click="index--">‹</button><span aria-label="Image position">{{ index + 1 }} / {{ series.images.length }}</span><button aria-label="Next image" :disabled="index + 1 >= series.images.length" @click="index++">›</button></span>
      <span v-if="image">{{ image.width }} × {{ image.height }}</span>
      <button v-if="image && allowSave !== false" :disabled="!url" @click="downloadRaster(image)">Save image…</button>
    </div>
  </section>
</template>
