<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'
import type { Project } from './api'
import NotebookIcon from './NotebookIcon.vue'
import { formatDate, readLibrary, saveLibrary } from './library'

const props = defineProps<{ projects: Project[]; accountId: string; busy: boolean }>()
defineEmits<{ refresh: [] }>()
const preferences = ref(readLibrary(props.accountId))
const expandedProjects = ref(new Set<string>())
const query = ref('')
const search = ref<HTMLInputElement>()
const sorted = computed(() => {
  const match = query.value.trim().toLocaleLowerCase()
  return props.projects.filter(project => project.title.toLocaleLowerCase().includes(match)).sort((a, b) => {
    if (preferences.value.sort === 'lastOpened') {
      const difference = (preferences.value.lastOpened[b.id] || 0) - (preferences.value.lastOpened[a.id] || 0)
      if (difference) return difference
    }
    if (preferences.value.sort === 'created' && a.created_at !== b.created_at) return b.created_at - a.created_at
    return a.title.localeCompare(b.title, undefined, { numeric: true, sensitivity: 'base' }) || a.id.localeCompare(b.id)
  })
})
watch(preferences, value => saveLibrary(props.accountId, value), { deep: true })

function toggleProject(id: string) {
  if (expandedProjects.value.has(id)) expandedProjects.value.delete(id)
  else expandedProjects.value.add(id)
}
async function focusSearch() {
  preferences.value.expanded = true
  await nextTick()
  search.value?.focus()
  search.value?.scrollIntoView({ block: 'nearest' })
}
defineExpose({ focusSearch })
</script>

<template>
  <section class="library" aria-label="Notebook Library" data-testid="notebook-library">
    <div class="library-heading">
      <h2><button class="library-toggle plain" :aria-expanded="preferences.expanded" aria-controls="library-content"
        :aria-label="`${preferences.expanded ? 'Collapse' : 'Expand'} Notebook Library`" @click="preferences.expanded = !preferences.expanded">
        <NotebookIcon name="chevron" :class="{ expanded: preferences.expanded }" />
        <span>Notebook Library</span><span class="library-count">{{ projects.length }}</span>
      </button></h2>
      <button class="icon-button plain" :disabled="busy" aria-label="Refresh library" title="Refresh library" @click="$emit('refresh')">
        <NotebookIcon name="refresh" :class="{ spinning: busy }" />
      </button>
    </div>
    <div v-if="preferences.expanded" id="library-content">
      <div class="library-tools">
        <div class="sort-control">
          <label for="library-sort">Sort by</label>
          <select id="library-sort" v-model="preferences.sort">
            <option value="lastOpened">Last Opened</option>
            <option value="created">Date Created</option>
            <option value="name">Name (A–Z)</option>
          </select>
        </div>
        <div class="library-search">
          <NotebookIcon name="search" />
          <input ref="search" v-model="query" type="search" aria-label="Find a notebook" placeholder="Find a notebook">
        </div>
      </div>
      <div v-if="!projects.length" class="library-empty">
        <NotebookIcon name="book" />
        <div><h3>Your notebooks, together.</h3><p>Create a notebook to start your library. Projects shared with you appear here, too.</p></div>
      </div>
      <div v-else-if="!sorted.length" class="library-empty" role="status">
        <NotebookIcon name="search" />
        <div><h3>No matching notebooks</h3><p>Try another name or <button class="text-button" @click="query = ''; search?.focus()">clear the search</button>.</p></div>
      </div>
      <div v-else class="library-projects">
        <article v-for="project in sorted" :key="project.id" class="library-project" data-testid="library-project">
          <div class="project-row">
            <button class="plain disclosure" :aria-label="`${expandedProjects.has(project.id) ? 'Hide' : 'Show'} details for ${project.title}`"
              :aria-expanded="expandedProjects.has(project.id)" :aria-controls="`details-${project.id}`" @click="toggleProject(project.id)">
              <NotebookIcon name="chevron" :class="{ expanded: expandedProjects.has(project.id) }" />
            </button>
            <a class="project-link" :href="`/projects/${encodeURIComponent(project.id)}`" :aria-label="`Open ${project.title}`">
              <NotebookIcon name="book" />
              <span class="project-label"><span class="project-name">{{ project.title }}</span>
                <span class="project-location">{{ project.role === 'owner' ? 'Your server workspace' : 'Shared with you' }}</span></span>
            </a>
            <span class="role-badge">{{ project.role }}</span>
            <a class="icon-button plain open-project" :href="`/projects/${encodeURIComponent(project.id)}`" :aria-label="`Open notebook ${project.title}`" title="Open notebook">
              <NotebookIcon name="arrow" />
            </a>
          </div>
          <div v-if="expandedProjects.has(project.id)" :id="`details-${project.id}`" class="project-details">
            <dl class="row-dates">
              <div><dt>Last opened on this browser</dt><dd>{{ preferences.lastOpened[project.id] ? formatDate(preferences.lastOpened[project.id]! / 1000) : 'Not opened here yet' }}</dd></div>
              <div><dt>Created</dt><dd><time :datetime="new Date(project.created_at * 1000).toISOString()">{{ formatDate(project.created_at) }}</time></dd></div>
              <div><dt>Updated</dt><dd>{{ formatDate(project.updated_at) }}</dd></div>
            </dl>
            <p class="project-id">Project ID <code>{{ project.id }}</code></p>
          </div>
        </article>
      </div>
      <p v-if="query.trim() && projects.length" class="search-count" role="status">{{ sorted.length }} of {{ projects.length }} notebooks</p>
    </div>
  </section>
</template>
